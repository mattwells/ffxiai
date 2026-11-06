--[[
MCP (Model Context Protocol) over HTTP for FFXI-AI. Runs on the host instance only.

Streamable HTTP transport, stateless: every POST /mcp carries one JSON-RPC message (or a batch) and gets a plain
application/json reply. There is no session id and no SSE stream, so a new host after a failover answers the
next request without the client noticing.
]]

local json = require('jsonx')
local net = require('net')

local mcp = {}

local SUPPORTED_VERSIONS = {'2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'}
local LATEST = SUPPORTED_VERSIONS[1]

local INSTRUCTIONS = [[
Read-only view of the user's Final Fantasy XI characters, through the FFXI-AI addon for Windower.
Nothing you call here changes anything in the game.
If the user plays more than one character at once, call list_characters first and pass "character" to the other
tools (or "all" to ask every character at once). With only one character logged in, "character" can be left out.]]

local character_param = {
    type = 'string',
    description = 'Character name, or "all" for every connected character. Can be left out when only one character is logged in.',
}

local function schema(props)
    local p = json.object({character = character_param})
    for k, v in pairs(props or {}) do
        p[k] = v
    end
    return {type = 'object', properties = p}
end

local READ_ONLY = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false}

local TOOLS = {
    {
        name = 'list_characters',
        title = 'List characters',
        description = 'Lists every game instance running FFXI-AI: character name, job, zone, status, HP/MP percent and TP.',
        inputSchema = {type = 'object', properties = json.object()},
    },
    {
        name = 'get_player',
        title = 'Player status',
        description = 'Character status: jobs and levels, HP/MP/TP, idle/engaged/resting/dead, active buffs and debuffs, every job\'s level.',
        inputSchema = schema(),
    },
    {
        name = 'get_target',
        title = 'Target',
        description = 'Current target, sub-target, battle target and pet: name, HP percent, distance, type and who has claim.',
        inputSchema = schema(),
    },
    {
        name = 'get_party',
        title = 'Party and alliance',
        description = 'Party and alliance members: HP/MP (and percent), TP, zone, distance when nearby, and the leader. '
            .. 'HP/MP/TP are null for members in another zone, because the game only reports them for your own zone.',
        inputSchema = schema(),
    },
    {
        name = 'get_inventory',
        title = 'Inventory',
        description = 'Items in a bag, with counts, plus gil. Without "bag" it reads the main inventory, or every bag when "search" is given. '
            .. 'Copies of an item are listed together only when they are identical: equipped copies and copies with different '
            .. 'augments get their own entries, and weapons and armour show their augments (and path and rank, for items that have them). '
            .. 'Bags: inventory, safe, safe2, storage, locker, satchel, sack, case, wardrobe, wardrobe2 to wardrobe8, temporary, recycle, or all.',
        inputSchema = schema({
            bag = {type = 'string', description = 'Bag to read, or "all".'},
            search = {type = 'string', description = 'Only items whose name contains this text (case-insensitive).'},
            whole_word = {type = 'boolean', description = 'With "search": match whole words only, so "ring" finds rings but not earrings.'},
        }),
    },
    {
        name = 'get_equipment',
        title = 'Equipment',
        description = 'What is equipped in each of the 16 slots, which bag it is in, and its augments. Items with a path '
            .. '(Odyssey, Sortie and similar) also show "path" and "rank"; what each rank gives is not in the game data.',
        inputSchema = schema(),
    },
    {
        name = 'get_recasts',
        title = 'Recasts',
        description = 'Job abilities and spells that are on cooldown, with seconds left.',
        inputSchema = schema(),
    },
    {
        name = 'get_location',
        title = 'Location',
        description = 'Zone, position, weather, Vana\'diel time and day, moon phase and server.',
        inputSchema = schema(),
    },
    {
        name = 'get_chat',
        title = 'Recent chat',
        description = 'Recent chat lines (say, shout, yell, party, linkshell, unity and so on) received while the addon was loaded. '
            .. 'Off unless the player turned it on in game; tells are left out unless they turned those on too.',
        inputSchema = schema({
            channel = {type = 'string', description = 'Only this channel, e.g. party, linkshell, linkshell2, say, shout, yell, unity, tell.'},
            limit = {type = 'integer', description = 'Most recent lines to return (default 50, max 200).'},
        }),
    },
    {
        name = 'get_merits',
        title = 'Merits and job points',
        description = 'Merit points available, the maximum and limit points; the merits with points spent in them; and per '
            .. 'job, capacity points, job points available and spent, and the job point categories with points in them.',
        inputSchema = schema({
            job = {type = 'string', description = 'Only this job, by its three-letter name (e.g. DNC).'},
        }),
    },
    {
        name = 'get_currencies',
        title = 'Currencies',
        description = 'Everything on the game\'s two Currencies pages (Sparks, Bayld, conquest points, seals, Escha beads '
            .. 'and silt, Gallimaufry, Hallmarks and so on), with how old each page is. The game only sends these when '
            .. 'the menu is opened: with requests off (the default) this shows the last time the player opened it; the '
            .. 'player can run //ffxiai requests on in game to let FFXI-AI ask for current values.',
        inputSchema = schema({
            search = {type = 'string', description = 'Only currencies whose name contains this text (case-insensitive).'},
        }),
    },
    {
        name = 'lookup',
        title = 'Look up game data',
        description = 'Searches Windower\'s game resources: items (stats as printed in game, level, jobs, slot, stack), '
            .. 'spells (MP, cast and recast times, element, level per job), job abilities, weapon skills (skillchain '
            .. 'properties), buffs, key items, job traits and zones. Search by name, id, or for items by the text of the '
            .. 'item\'s description (e.g. "store tp"). With "owned": true it only returns what the character has: items '
            .. 'in their bags (with where and how many), key items held, spells learned, or abilities and weapon skills '
            .. 'usable on their current jobs. Item descriptions show base stats only, not augments, path or rank. '
            .. '"character" is only needed with "owned".',
        inputSchema = schema({
            kind = {type = 'string', enum = {'item', 'spell', 'ability', 'weapon_skill', 'buff', 'key_item', 'job_trait', 'zone'},
                description = 'What to look up (default item).'},
            name = {type = 'string', description = 'Name contains this text (case-insensitive).'},
            whole_word = {type = 'boolean', description = 'With "name": match whole words only.'},
            id = {type = 'integer', description = 'Exact resource id.'},
            text = {type = 'string', description = 'Items only: description contains this text (case-insensitive).'},
            owned = {type = 'boolean', description = 'Only what this character has (needs "character" when several are logged in).'},
            limit = {type = 'integer', description = 'Most results to return (default 20, max 100).'},
        }),
    },
}

for _, t in ipairs(TOOLS) do
    t.annotations = READ_ONLY
end

local KNOWN = {}
for _, t in ipairs(TOOLS) do
    KNOWN[t.name] = true
end

-- Tool calls ---------------------------------------------------------------------

local function names_of(list)
    local names = {}
    for _, inst in ipairs(list) do
        names[#names + 1] = inst.name or '(not logged in)'
    end
    return table.concat(names, ', ')
end

-- Returns a list of instances, whether the reply is keyed by name ("all"), or nil and an error.
local function resolve(character)
    local all = net.instances()
    if type(character) ~= 'string' or character == '' then
        local logged = {}
        for _, inst in ipairs(all) do
            if inst.name then
                logged[#logged + 1] = inst
            end
        end
        if #logged == 1 then
            return logged, false
        elseif #logged == 0 then
            return nil, 'No character is logged in.'
        end
        return nil, 'Several characters are logged in (' .. names_of(logged) .. '). Pass "character" with one of those names, or "all".'
    end
    if character:lower() == 'all' then
        return all, true
    end
    for _, inst in ipairs(all) do
        if inst.name and inst.name:lower() == character:lower() then
            return {inst}, false
        end
    end
    return nil, 'No character named "' .. character .. '" is connected. Connected: ' .. names_of(all) .. '.'
end

-- Runs tool on each instance; cb(table_by_name) once all have answered.
local function fan_out(instances, tool, args, cb)
    local results, left = {}, #instances
    if left == 0 then
        return cb(results)
    end
    for i, inst in ipairs(instances) do
        net.request(inst, tool, args, function(result, err)
            results[i] = {inst = inst, result = result, err = err}
            left = left - 1
            if left == 0 then
                cb(results)
            end
        end)
    end
end

local function text_result(data, is_error)
    local text = type(data) == 'string' and data or json.encode(data)
    return {content = json.array({{type = 'text', text = text}}), isError = is_error and true or false}
end

local function key_for(inst, used)
    local key = inst.name or 'not logged in'
    if used[key] then
        key = key .. ' (' .. inst.iid:sub(1, 6) .. ')'
    end
    used[key] = true
    return key
end

local function call_tool(params, reply)
    local name = params.name
    local args = type(params.arguments) == 'table' and params.arguments or json.object()
    if not KNOWN[name] then
        return reply(nil, {code = -32602, message = 'Unknown tool: ' .. tostring(name)})
    end

    if name == 'list_characters' then
        return fan_out(net.instances(), 'summary', json.object(), function(results)
            local list = json.array()
            for _, r in ipairs(results) do
                local entry = type(r.result) == 'table' and r.result or {logged_in = false}
                entry.name = entry.name or r.inst.name or json.null
                entry.hosting = r.inst.host
                if r.err then
                    entry.error = r.err
                end
                list[#list + 1] = entry
            end
            reply(text_result({characters = list}))
        end)
    end

    local targets, by_name
    if name == 'lookup' and args.owned ~= true and (type(args.character) ~= 'string' or args.character == '') then
        -- Game data is the same on every instance, so any one will do. This runs on the host, which
        -- net.instances() lists first, and the host answers fastest.
        targets, by_name = {net.instances()[1]}, false
    else
        targets, by_name = resolve(args.character)
    end
    if not targets or not targets[1] then
        return reply(text_result(type(by_name) == 'string' and by_name or 'No game instance is connected.', true))
    end
    local forwarded = json.object()
    for k, v in pairs(args) do
        if k ~= 'character' then
            forwarded[k] = v
        end
    end
    fan_out(targets, name, forwarded, function(results)
        if not by_name then
            local r = results[1]
            if r.err or r.result == nil then
                return reply(text_result((r.inst.name or 'That character') .. ': ' .. tostring(r.err or 'no data'), true))
            end
            return reply(text_result(r.result))
        end
        local out, used = json.object(), {}
        for _, r in ipairs(results) do
            out[key_for(r.inst, used)] = r.err and {error = r.err} or r.result
        end
        reply(text_result(out))
    end)
end

-- JSON-RPC -----------------------------------------------------------------------

local function negotiate(requested)
    for _, v in ipairs(SUPPORTED_VERSIONS) do
        if v == requested then
            return v
        end
    end
    return LATEST
end

-- Handles one message. done(response_or_nil): nil for notifications.
local function handle_message(msg, done)
    if type(msg) ~= 'table' or msg.jsonrpc ~= '2.0' or type(msg.method) ~= 'string' then
        if type(msg) == 'table' and msg.method == nil and (msg.result ~= nil or msg.error ~= nil) then
            return done(nil) -- a response from the client; we never ask it anything
        end
        return done({jsonrpc = '2.0', id = json.null, error = {code = -32600, message = 'Invalid Request'}})
    end
    local id = msg.id
    local is_notification = id == nil
    local params = type(msg.params) == 'table' and msg.params or json.object()

    local function reply(result, err)
        if is_notification then
            return done(nil)
        end
        if err then
            return done({jsonrpc = '2.0', id = id, error = err})
        end
        done({jsonrpc = '2.0', id = id, result = result})
    end

    local m = msg.method
    if m == 'initialize' then
        reply({
            protocolVersion = negotiate(params.protocolVersion),
            capabilities = {tools = {listChanged = false}},
            serverInfo = {name = 'ffxiai', title = 'FFXI-AI', version = net.version},
            instructions = INSTRUCTIONS,
        })
    elseif m == 'ping' then
        reply(json.object())
    elseif m == 'tools/list' then
        reply({tools = json.array(TOOLS)})
    elseif m == 'tools/call' then
        call_tool(params, reply)
    elseif m:sub(1, 14) == 'notifications/' then
        done(nil)
    else
        reply(nil, {code = -32601, message = 'Method not found: ' .. m})
    end
end

-- HTTP ------------------------------------------------------------------------------

local LOCAL_HOSTS = {['127.0.0.1'] = true, ['localhost'] = true, ['[::1]'] = true}

local function host_part(value)
    if not value then
        return nil
    end
    value = value:lower()
    if value:sub(1, 1) == '[' then
        return value:match('^(%[[^%]]*%])')
    end
    return value:match('^([^:]+)')
end

local JSON_HEADERS = {['Content-Type'] = 'application/json'}

function mcp.handle_http(req, respond)
    -- Only local pages and programs may talk to us (guards against DNS rebinding from a web page).
    local origin = req.headers['origin']
    if origin and not LOCAL_HOSTS[host_part(origin:match('^%a+://(.*)$')) or ''] then
        return respond('403 Forbidden', {['Content-Type'] = 'text/plain'}, 'origin not allowed')
    end
    if not LOCAL_HOSTS[host_part(req.headers['host']) or ''] then
        return respond('403 Forbidden', {['Content-Type'] = 'text/plain'}, 'host not allowed')
    end

    local path = req.path:match('^[^?]*')
    if path ~= '/mcp' and path ~= '/mcp/' and path ~= '/' then
        return respond('404 Not Found', {['Content-Type'] = 'text/plain'}, 'FFXI-AI serves MCP at /mcp')
    end
    if req.method ~= 'POST' then
        return respond('405 Method Not Allowed', {Allow = 'POST'}, '')
    end

    local body, err = json.decode(req.body)
    if body == nil then
        return respond('400 Bad Request', JSON_HEADERS, json.encode({
            jsonrpc = '2.0', id = json.null, error = {code = -32700, message = 'Parse error: ' .. tostring(err)},
        }))
    end

    local mt = getmetatable(body)
    local batch = mt and mt.__jsontype == 'array'
    local messages = batch and body or {body}
    if #messages == 0 then
        return respond('400 Bad Request', JSON_HEADERS, json.encode({
            jsonrpc = '2.0', id = json.null, error = {code = -32600, message = 'Empty batch'},
        }))
    end

    local responses, left = {}, #messages
    local function finished()
        local list = json.array()
        for i = 1, #messages do
            if responses[i] then
                list[#list + 1] = responses[i]
            end
        end
        if #list == 0 then
            return respond('202 Accepted', {}, '')
        end
        respond('200 OK', JSON_HEADERS, json.encode(batch and list or list[1]))
    end
    for i, msg in ipairs(messages) do
        handle_message(msg, function(response)
            responses[i] = response or false
            left = left - 1
            if left == 0 then
                finished()
            end
        end)
    end
end

return mcp
