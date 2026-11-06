--[[
Networking for FFXI-AI. Everything is non-blocking and driven by net.update(), called once per frame.

Every game instance runs the same addon. The first one to bind 127.0.0.1:<port> is the host: it serves
MCP over HTTP and accepts the other instances (peers) on the same port. The first byte tells them apart:
HTTP requests start with a method name, peer messages with '{' (one JSON object per line).
If the host goes away, each peer tries to bind after a short random delay; the winner becomes the new host
and the rest join it.

Peer protocol (newline-delimited JSON):
  peer -> host  {"t":"hello","iid":"...","name":"Eione"|null,"v":"0.1.0"}   (sent again when the name changes)
  host -> peer  {"t":"welcome","v":"0.1.0"}
  host -> peer  {"t":"req","id":7,"tool":"get_player","args":{...}}
  peer -> host  {"t":"res","id":7,"result":{...}}  or  {"t":"res","id":7,"error":"..."}
]]

local socket = require('socket')
local json = require('jsonx')

local net = {}

local CONNECT_TIMEOUT = 3   -- seconds for a peer to reach the host
local HELLO_TIMEOUT = 3     -- seconds for the host to welcome a peer
local REQUEST_TIMEOUT = 5   -- seconds the host waits on a peer's answer (tools may wait ~2s on the game)
local HTTP_IDLE = 15        -- seconds a client has to send a complete request
local HTTP_MAX_AGE = 30     -- seconds before an unanswered HTTP request is dropped
local MAX_BUFFER = 1048576

net.port = 19750
net.version = '0'
net.role = 'starting'       -- 'host', 'joining', 'peer', 'waiting'
net.name = nil              -- this instance's character, nil when not logged in
net.iid = nil               -- random id for this instance
net.problem = nil           -- last reason we couldn't host or join, for //ffxiai status
net.served = 0              -- HTTP requests answered (host only)
net.last_request = nil      -- socket.gettime() of the last HTTP request

-- Set by the addon:
net.run_local = function(tool, args) return nil, 'not ready' end  -- returns result or nil, error
net.on_http = function(req, respond) respond('404 Not Found', {}, '') end
net.log = function(msg) end

local server            -- host: listening socket
local conns = {}        -- host: accepted connections (HTTP clients and peers)
local peers = {}        -- host: iid -> conn
local pending = {}      -- host: request id -> {conn, cb, deadline}
local next_id = 0
local link              -- peer: connection to the host
local next_attempt = 0
local failures = 0

local function now()
    return socket.gettime()
end

function net.init(port, version)
    net.port = port
    net.version = version
    math.randomseed(math.floor(now() * 1000) % 2147483647 + tonumber(tostring({}):match('%x+$') or '0', 16) % 100000)
    net.iid = string.format('%08x%08x', math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

-- Connection helpers -----------------------------------------------------------

local function new_conn(sock, t)
    return {sock = sock, buf = '', out = '', born = t, seen = t}
end

local function fail_pending(c, reason)
    local hit = {}
    for id, p in pairs(pending) do
        if p.conn == c then
            hit[#hit + 1] = id
        end
    end
    for _, id in ipairs(hit) do
        local p = pending[id]
        pending[id] = nil
        p.cb(nil, reason)
    end
end

local function close_conn(c)
    if c.closed then
        return
    end
    c.closed = true
    pcall(c.sock.close, c.sock)
    if c.iid and peers[c.iid] == c then
        peers[c.iid] = nil
        net.log('Peer left: ' .. (c.name or 'not logged in'))
        fail_pending(c, 'that character disconnected')
    end
end

-- Reads whatever is available. Returns false once the other side has closed.
local function read(c)
    for _ = 1, 64 do
        local data, err, partial = c.sock:receive(8192)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            c.buf = c.buf .. chunk
            c.seen = now()
        end
        if not data then
            return err == 'timeout'
        end
    end
    return true
end

-- Writes as much as the socket takes. Returns false when the connection should close.
local function flush(c)
    while #c.out > 0 do
        local last, err, partial_last = c.sock:send(c.out)
        local sent = last or partial_last or 0
        if sent > 0 then
            c.out = c.out:sub(sent + 1)
        end
        if not last then
            return err == 'timeout'
        end
    end
    return not c.close_when_done
end

local function send_msg(c, msg)
    c.out = c.out .. json.encode(msg) .. '\n'
end

local function each_line(c, fn)
    while not c.closed do
        local nl = c.buf:find('\n', 1, true)
        if not nl then
            return
        end
        local line = c.buf:sub(1, nl - 1)
        c.buf = c.buf:sub(nl + 1)
        if line:find('%S') then
            local msg = json.decode(line)
            if type(msg) == 'table' then
                fn(msg)
            end
        end
    end
end

local function str(v)
    return type(v) == 'string' and v ~= '' and v or nil
end

-- HTTP ---------------------------------------------------------------------------

local function http_response(status, headers, body)
    body = body or ''
    local lines = {'HTTP/1.1 ' .. status}
    for k, v in pairs(headers) do
        lines[#lines + 1] = k .. ': ' .. tostring(v)
    end
    lines[#lines + 1] = 'Content-Length: ' .. #body
    lines[#lines + 1] = 'Connection: close'
    return table.concat(lines, '\r\n') .. '\r\n\r\n' .. body
end

-- Returns nil while incomplete, 'bad' for garbage, or {method, path, headers, body}.
local function parse_http(buf)
    local head_end = buf:find('\r\n\r\n', 1, true)
    if not head_end then
        return #buf > 65536 and 'bad' or nil
    end
    local head = buf:sub(1, head_end - 1)
    local method, path = head:match('^(%u+) (%S+) HTTP/%d%.%d')
    if not method then
        return 'bad'
    end
    local headers = {}
    for name, value in head:gmatch('\r\n([^:\r\n]+):[ \t]*([^\r\n]*)') do
        headers[name:lower()] = value
    end
    local rest = buf:sub(head_end + 4)
    local body
    if (headers['transfer-encoding'] or ''):lower():find('chunked') then
        local parts, i = {}, 1
        while true do
            local line_end = rest:find('\r\n', i, true)
            if not line_end then return nil end
            local size = tonumber(rest:sub(i, line_end - 1):match('^%x+'), 16)
            if not size then return 'bad' end
            if size == 0 then
                break
            end
            if #rest < line_end + 1 + size + 2 then return nil end
            parts[#parts + 1] = rest:sub(line_end + 2, line_end + 1 + size)
            i = line_end + 2 + size + 2
        end
        body = table.concat(parts)
    else
        local len = tonumber(headers['content-length'] or '0')
        if not len then return 'bad' end
        if #rest < len then return nil end
        body = rest:sub(1, len)
    end
    return {method = method, path = path, headers = headers, body = body}
end

-- Host -----------------------------------------------------------------------------

local function host_peer_msg(c, msg)
    if msg.t == 'hello' then
        local iid = str(msg.iid)
        if not iid then
            return
        end
        if peers[iid] and peers[iid] ~= c then
            close_conn(peers[iid])
        end
        local was = c.name
        c.iid, c.name, c.version = iid, str(msg.name), str(msg.v)
        peers[iid] = c
        if not c.welcomed then
            c.welcomed = true
            send_msg(c, {t = 'welcome', v = net.version})
            net.log('Peer joined: ' .. (c.name or 'not logged in'))
        elseif was ~= c.name then
            net.log('Peer is now: ' .. (c.name or 'not logged in'))
        end
    elseif msg.t == 'res' and c.iid then
        local p = pending[msg.id]
        if p and p.conn == c then
            pending[msg.id] = nil
            if msg.error ~= nil and msg.error ~= json.null then
                p.cb(nil, tostring(msg.error))
            else
                p.cb(msg.result)
            end
        end
    end
end

local function host_http(c, t)
    local req = parse_http(c.buf)
    if not req then
        return
    end
    c.request = true
    c.request_time = t
    if req == 'bad' then
        c.out = http_response('400 Bad Request', {}, '')
        c.close_when_done = true
        return
    end
    net.served = net.served + 1
    net.last_request = t
    local function respond(status, headers, body)
        if c.closed or c.close_when_done then
            return
        end
        c.out = c.out .. http_response(status, headers or {}, body)
        c.close_when_done = true
    end
    local ok, err = pcall(net.on_http, req, respond)
    if not ok then
        net.log('Error handling request: ' .. tostring(err))
        respond('500 Internal Server Error', {['Content-Type'] = 'text/plain'}, 'internal error')
    end
end

local function host_update(t)
    for _ = 1, 16 do
        local s = server:accept()
        if not s then
            break
        end
        s:settimeout(0)
        conns[#conns + 1] = new_conn(s, t)
    end

    for i = #conns, 1, -1 do
        local c = conns[i]
        local alive = not c.closed and read(c) and #c.buf <= MAX_BUFFER
        if alive then
            if not c.kind and #c.buf > 0 then
                c.kind = c.buf:sub(1, 1) == '{' and 'peer' or 'http'
            end
            if c.kind == 'peer' then
                each_line(c, function(msg) host_peer_msg(c, msg) end)
            elseif c.kind == 'http' and not c.request then
                host_http(c, t)
            end
            if c.kind ~= 'peer' then
                if not c.request and t - c.born > HTTP_IDLE then
                    alive = false
                elseif c.request and t - c.request_time > HTTP_MAX_AGE then
                    alive = false
                end
            end
            alive = alive and not c.closed and flush(c)
        end
        if not alive then
            close_conn(c)
            table.remove(conns, i)
        end
    end

    local expired = {}
    for id, p in pairs(pending) do
        if t > p.deadline then
            expired[#expired + 1] = id
        end
    end
    for _, id in ipairs(expired) do
        local p = pending[id]
        pending[id] = nil
        p.cb(nil, 'that character did not answer in time')
    end
end

-- Lists every instance the host knows about, itself first.
function net.instances()
    local list = {{iid = net.iid, name = net.name, host = true}}
    for iid, c in pairs(peers) do
        list[#list + 1] = {iid = iid, name = c.name, host = false}
    end
    return list
end

-- Runs a tool on this instance. A tool can answer later by returning a function: it is called with a
-- callback(result, err) to call once the answer is ready (e.g. after the game replies to a request).
local function run_here(tool, args, cb)
    local ok, result, err = pcall(net.run_local, tool, args)
    if not ok then
        return cb(nil, 'error: ' .. tostring(result))
    end
    if type(result) == 'function' then
        local answered = false
        local ok2, e = pcall(result, function(r, er)
            if not answered then
                answered = true
                cb(r, er)
            end
        end)
        if not ok2 and not answered then
            answered = true
            cb(nil, 'error: ' .. tostring(e))
        end
        return
    end
    return cb(result, err)
end

-- Asks one instance (from net.instances) to run a tool. cb(result) or cb(nil, error), now or later.
function net.request(instance, tool, args, cb)
    if instance.iid == net.iid then
        return run_here(tool, args, cb)
    end
    local c = peers[instance.iid]
    if not c or c.closed then
        return cb(nil, 'that character disconnected')
    end
    next_id = next_id + 1
    pending[next_id] = {conn = c, cb = cb, deadline = now() + REQUEST_TIMEOUT}
    send_msg(c, {t = 'req', id = next_id, tool = tool, args = args or json.object()})
end

-- Peer ------------------------------------------------------------------------------

local function drop_link(reason, delay)
    if link then
        pcall(link.sock.close, link.sock)
        link = nil
    end
    if net.role == 'peer' then
        net.log('Lost the host (' .. reason .. '), looking for a new one.')
    end
    net.role = 'waiting'
    net.problem = reason
    next_attempt = now() + (delay or (0.1 + math.random() * 1.4))
end

local function peer_hello(l)
    send_msg(l, {t = 'hello', iid = net.iid, name = net.name, v = net.version})
    l.sent_name = net.name or false
end

local function peer_update(t)
    local l = link
    if l.state == 'connecting' then
        local _, writable = socket.select(nil, {l.sock}, 0)
        if writable and (writable[1] or writable[l.sock]) then
            l.state = 'open'
        elseif t - l.since > CONNECT_TIMEOUT then
            failures = failures + 1
            return drop_link('could not reach the host', math.min(2 * failures, 10))
        else
            return
        end
    end
    if l.state == 'open' then
        peer_hello(l)
        l.state = 'hello'
        l.since = t
    end
    if not read(l) then
        return drop_link('the host closed the connection')
    end
    each_line(l, function(msg)
        if msg.t == 'welcome' and l.state == 'hello' then
            l.state = 'ready'
            net.role = 'peer'
            net.problem = nil
            failures = 0
            net.log('Joined the host on port ' .. net.port .. '.')
        elseif msg.t == 'req' and l.state == 'ready' then
            local args = type(msg.args) == 'table' and msg.args or json.object()
            run_here(tostring(msg.tool), args, function(result, err)
                send_msg(l, {t = 'res', id = msg.id, result = result, error = err})
            end)
        end
    end)
    if l.state == 'hello' and t - l.since > HELLO_TIMEOUT then
        failures = failures + 1
        return drop_link('port ' .. net.port .. ' is in use by another program', 10)
    end
    if l.state == 'ready' and l.sent_name ~= (net.name or false) then
        peer_hello(l)
    end
    if not flush(l) then
        return drop_link('the host closed the connection')
    end
end

-- Election --------------------------------------------------------------------------

local function new_tcp()
    return (socket.tcp4 or socket.tcp)()
end

-- Binds without SO_REUSEADDR: on Windows that option would let a second instance bind the same port.
local function try_host()
    local s = new_tcp()
    s:settimeout(0)
    local ok, err = s:bind('127.0.0.1', net.port)
    if ok then
        ok, err = s:listen(32)
    end
    if not ok then
        s:close()
        return false, err
    end
    server = s
    return true
end

local function try_join(t)
    local s = new_tcp()
    s:settimeout(0)
    local ok, err = s:connect('127.0.0.1', net.port)
    if not ok and err ~= 'timeout' then
        s:close()
        return false, err
    end
    link = new_conn(s, t)
    link.state = ok and 'open' or 'connecting'
    link.since = t
    return true
end

local function attempt(t)
    local ok, bind_err = try_host()
    if ok then
        net.role = 'host'
        net.problem = nil
        failures = 0
        net.log('Hosting at http://127.0.0.1:' .. net.port .. '/mcp')
        return
    end
    local joined, join_err = try_join(t)
    if joined then
        net.role = 'joining'
        return
    end
    failures = failures + 1
    net.role = 'waiting'
    net.problem = 'could not open port ' .. net.port .. ' (' .. tostring(bind_err or join_err) .. ')'
    next_attempt = t + math.min(2 * failures, 10)
end

function net.update()
    local t = now()
    if net.role == 'host' then
        host_update(t)
    elseif link then
        peer_update(t)
    elseif t >= next_attempt then
        attempt(t)
    end
end

function net.peer_count()
    local n = 0
    for _ in pairs(peers) do
        n = n + 1
    end
    return n
end

function net.shutdown()
    for _, c in ipairs(conns) do
        close_conn(c)
    end
    conns = {}
    if server then
        pcall(server.close, server)
        server = nil
    end
    if link then
        pcall(link.sock.close, link.sock)
        link = nil
    end
    net.role = 'stopped'
end

return net
