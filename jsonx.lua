--[[
JSON encoder/decoder for FFXI-AI. Windower's libs/json.lua only reads files, so this one does both.

Lua tables are ambiguous (is {} an object or an array?), so:
  json.array(t)   marks t as an array, even when empty
  json.object(t)  marks t as an object, even when empty
  json.null       stands for JSON null
Unmarked tables are arrays when their keys are exactly 1..n (n > 0), objects otherwise.
Encoded strings are always valid UTF-8: bytes that aren't are replaced with U+FFFD.
]]

local json = {}

local array_mt = {__jsontype = 'array'}
local object_mt = {__jsontype = 'object'}

json.null = setmetatable({}, {__jsontype = 'null', __tostring = function() return 'null' end})

function json.array(t) return setmetatable(t or {}, array_mt) end
function json.object(t) return setmetatable(t or {}, object_mt) end

local function kind(t)
    local mt = getmetatable(t)
    if mt and mt.__jsontype then
        return mt.__jsontype
    end
    local n = #t
    if n == 0 then
        return 'object'
    end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then
            return 'object'
        end
        count = count + 1
    end
    return count == n and 'array' or 'object'
end

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local REPLACEMENT = '\239\191\189'

-- Keeps valid UTF-8 sequences, replaces anything else with U+FFFD.
local function clean_utf8(s)
    if not s:find('[\128-\255]') then
        return s
    end
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else len = 0 end
        local ok = len > 0 and i + len - 1 <= n
        if ok and len > 1 then
            for j = i + 1, i + len - 1 do
                local b = s:byte(j)
                if b < 0x80 or b > 0xBF then ok = false break end
            end
            if ok then
                local b2 = s:byte(i + 1)
                if (c == 0xE0 and b2 < 0xA0) or (c == 0xED and b2 > 0x9F)
                    or (c == 0xF0 and b2 < 0x90) or (c == 0xF4 and b2 > 0x8F) then
                    ok = false
                end
            end
        end
        if ok then
            out[#out + 1] = s:sub(i, i + len - 1)
            i = i + len
        else
            out[#out + 1] = REPLACEMENT
            i = i + 1
        end
    end
    return table.concat(out)
end

local function encode_string(s)
    s = clean_utf8(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        return 'null'
    end
    if n % 1 == 0 and n > -1e15 and n < 1e15 then
        return string.format('%d', n)
    end
    return string.format('%.14g', n)
end

local encode_value

local function encode_table(t, seen)
    if seen[t] then
        error('json: cycle in table')
    end
    seen[t] = true
    local k = kind(t)
    local parts = {}
    if k == 'null' then
        seen[t] = nil
        return 'null'
    elseif k == 'array' then
        for i = 1, #t do
            parts[i] = encode_value(t[i], seen)
        end
        seen[t] = nil
        return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for key, v in pairs(t) do
        if type(v) ~= 'function' then
            keys[#keys + 1] = tostring(key)
        end
    end
    table.sort(keys)
    for i, key in ipairs(keys) do
        local v = t[key]
        if v == nil then
            v = t[tonumber(key)]
        end
        parts[i] = encode_string(key) .. ':' .. encode_value(v, seen)
    end
    seen[t] = nil
    return '{' .. table.concat(parts, ',') .. '}'
end

encode_value = function(v, seen)
    local tv = type(v)
    if tv == 'nil' then return 'null'
    elseif tv == 'boolean' then return v and 'true' or 'false'
    elseif tv == 'number' then return encode_number(v)
    elseif tv == 'string' then return encode_string(v)
    elseif tv == 'table' then return encode_table(v, seen)
    end
    return encode_string(tostring(v))
end

function json.encode(v)
    return encode_value(v, {})
end

-- Decoding --------------------------------------------------------------------

local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local decode_value

local function skip(s, i)
    return s:find('[^ \t\r\n]', i) or #s + 1
end

local function fail(s, i, msg)
    error(string.format('json: %s at position %d', msg, i), 0)
end

local function decode_string(s, i)
    local out = {}
    local j = i + 1
    while true do
        local a, b = s:find('["\\]', j)
        if not a then fail(s, i, 'unterminated string') end
        out[#out + 1] = s:sub(j, a - 1)
        if s:sub(a, a) == '"' then
            return table.concat(out), a + 1
        end
        local e = s:sub(a + 1, a + 1)
        local simple = ({['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'})[e]
        if simple then
            out[#out + 1] = simple
            j = a + 2
        elseif e == 'u' then
            local hex = s:sub(a + 2, a + 5)
            if not hex:find('^%x%x%x%x$') then fail(s, a, 'bad \\u escape') end
            local cp = tonumber(hex, 16)
            j = a + 6
            if cp >= 0xD800 and cp <= 0xDBFF then
                local lo = s:match('^\\u(%x%x%x%x)', j)
                local low = lo and tonumber(lo, 16)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                    j = j + 6
                else
                    cp = 0xFFFD
                end
            elseif cp >= 0xDC00 and cp <= 0xDFFF then
                cp = 0xFFFD
            end
            out[#out + 1] = utf8_char(cp)
        else
            fail(s, a, 'bad escape')
        end
    end
end

local function decode_array(s, i)
    local t = json.array({})
    i = skip(s, i + 1)
    if s:sub(i, i) == ']' then
        return t, i + 1
    end
    while true do
        local v
        v, i = decode_value(s, i)
        t[#t + 1] = v
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == ']' then return t, i + 1 end
        if c ~= ',' then fail(s, i, "expected ',' or ']'") end
        i = skip(s, i + 1)
    end
end

local function decode_object(s, i)
    local t = json.object({})
    i = skip(s, i + 1)
    if s:sub(i, i) == '}' then
        return t, i + 1
    end
    while true do
        if s:sub(i, i) ~= '"' then fail(s, i, 'expected string key') end
        local k
        k, i = decode_string(s, i)
        i = skip(s, i)
        if s:sub(i, i) ~= ':' then fail(s, i, "expected ':'") end
        local v
        v, i = decode_value(s, skip(s, i + 1))
        t[k] = v
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == '}' then return t, i + 1 end
        if c ~= ',' then fail(s, i, "expected ',' or '}'") end
        i = skip(s, i + 1)
    end
end

decode_value = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == '{' then return decode_object(s, i)
    elseif c == '[' then return decode_array(s, i)
    elseif c == '"' then return decode_string(s, i)
    elseif s:sub(i, i + 3) == 'true' then return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then return json.null, i + 4
    end
    local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
    if num and num ~= '' and tonumber(num) then
        return tonumber(num), i + #num
    end
    fail(s, i, 'unexpected character')
end

-- Returns value, or nil and an error message.
function json.decode(s)
    local ok, v, i = pcall(decode_value, s, 1)
    if not ok then
        return nil, v
    end
    if skip(s, i) <= #s then
        return nil, 'json: trailing data'
    end
    return v
end

return json
