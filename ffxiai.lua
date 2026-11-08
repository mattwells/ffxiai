--[[
FFXI-AI - lets an AI assistant (Claude and others that speak MCP) see your FFXI game state: status, target,
party, inventory, equipment, recasts, location, merits and job points, currencies and, if you allow it, recent
chat. Read-only by default: it never sends anything to the game server unless you turn on requests (below).

Install: put this folder in Windower/addons/ffxiai/ then  //lua load ffxiai  (or add that line to scripts/init.txt)
Load it on every character. The first one becomes the host at http://127.0.0.1:19750/mcp and the rest connect
to it, so one address covers them all. If the host closes, another character takes over by itself.

The command is only for checking on it:
  //ffxiai                  status: hosting or connected, which characters, requests served
  //ffxiai chat [on|off]    let the AI read recent chat for this character (off by default)
  //ffxiai tells [on|off]   include tells in that chat (off by default)
  //ffxiai requests [on|off]  let FFXI-AI ask the game server for data, the same requests opening a menu
                            sends (currencies). Off by default; while off, nothing is ever sent.
  //ffxiai log [on|off]     print connection events in the chat log
Settings are saved per character in data/settings.xml.
The port is in data/settings.xml (global section); every character must use the same one.
]]

_addon.name = 'FFXI-AI'
_addon.author = 'Andro'
_addon.version = '0.5.1'
_addon.commands = {'ffxiai'}

local config = require('config')
local net = require('net')
local mcp = require('mcp')
local tools = require('tools')

local defaults = {
    port = 19750,
    log = false,
    requests = false, -- anything that sends packets to the game server checks this
    chat = {
        enabled = false,
        tells = false,
    },
}

local settings = config.load(defaults)
tools.settings = settings

local function say(text)
    windower.add_to_chat(207, 'FFXI-AI: ' .. text)
end

net.log = function(msg)
    if settings.log then
        say(msg)
    end
end
net.on_http = mcp.handle_http
net.run_local = tools.run

local function current_name()
    local info = windower.ffxi.get_info()
    local player = info and info.logged_in and windower.ffxi.get_player()
    return player and player.name or nil
end

local started = false
local next_name_check = 0
local shown_problem

local function start()
    if started then
        return
    end
    started = true
    net.init(tonumber(settings.port) or 19750, _addon.version)
    net.name = current_name()
    tools.seed_packets()
end

windower.register_event('incoming chunk', function(id, data)
    tools.record_packet(id, data)
end)

windower.register_event('load', start)

windower.register_event('unload', function()
    net.shutdown()
end)

windower.register_event('login', function(name)
    net.name = name
end)

windower.register_event('logout', function()
    net.name = nil
end)

windower.register_event('prerender', function()
    if not started then
        return
    end
    local t = os.clock()
    -- Login and logout keep the name up to date; this only fills it in if it isn't known yet.
    if not net.name and t >= next_name_check then
        next_name_check = t + 1
        net.name = current_name()
    end
    net.update()
    -- Problems the player can fix are shown once each, even with logging off.
    local p = net.problem
    if p and p ~= shown_problem and (p:find('another program', 1, true) or p:find('could not open', 1, true)) then
        shown_problem = p
        say(p .. '. Change the port in data/settings.xml on every character, then reload.')
    end
end)

windower.register_event('chat message', function(message, sender, mode)
    tools.record_chat(message, sender, mode)
end)

local function on_off(value, current)
    if value == 'on' then return true end
    if value == 'off' then return false end
    return not current
end

local function ago(t)
    return t and tools.age_text(t, true) or 'none yet'
end

local function status()
    local url = 'http://127.0.0.1:' .. net.port .. '/mcp'
    if net.role == 'host' then
        local others = {}
        for _, inst in ipairs(net.instances()) do
            if not inst.host then
                others[#others + 1] = inst.name or '(not logged in)'
            end
        end
        say('v' .. _addon.version .. ', hosting at ' .. url)
        say(#others == 0 and 'No other characters connected.'
            or ('Other characters connected: ' .. table.concat(others, ', ')))
        say('Requests served: ' .. net.served .. ', last ' .. ago(net.last_request))
    elseif net.role == 'peer' then
        say('v' .. _addon.version .. ', connected to the host at ' .. url)
    else
        say('v' .. _addon.version .. ', looking for the host on port ' .. net.port
            .. (net.problem and (' (' .. net.problem .. ')') or ''))
    end
    say('Chat for this character: ' .. (settings.chat.enabled and 'on' or 'off')
        .. (settings.chat.enabled and (settings.chat.tells and ', tells included' or ', tells left out') or ''))
    say('Requests to the game server: ' .. (settings.requests and 'on' or 'off'))
    local seen = tools.packets_summary()
    for _, kind in ipairs(tools.DATA_KINDS) do
        say('  ' .. kind .. ': ' .. seen[kind])
    end
end

windower.register_event('addon command', function(cmd, value)
    cmd = cmd and cmd:lower() or 'status'
    value = value and value:lower()
    if cmd == 'status' then
        status()
    elseif cmd == 'chat' then
        settings.chat.enabled = on_off(value, settings.chat.enabled)
        if not settings.chat.enabled then
            tools.chat = {}
        end
        config.save(settings)
        say('Chat reading for this character is ' .. (settings.chat.enabled and 'on' or 'off') .. '.')
    elseif cmd == 'tells' then
        settings.chat.tells = on_off(value, settings.chat.tells)
        config.save(settings)
        say('Tells are ' .. (settings.chat.tells and 'included in' or 'left out of') .. ' chat.'
            .. (settings.chat.enabled and '' or ' (Chat reading itself is off: //ffxiai chat on)'))
    elseif cmd == 'requests' then
        settings.requests = on_off(value, settings.requests)
        config.save(settings)
        say('Requests to the game server are ' .. (settings.requests and 'on' or 'off') .. '. '
            .. (settings.requests and 'FFXI-AI may send the same requests opening a menu sends (currencies).'
                or 'FFXI-AI sends nothing to the game server.'))
    elseif cmd == 'log' then
        settings.log = on_off(value, settings.log)
        config.save(settings)
        say('Logging is ' .. (settings.log and 'on' or 'off') .. '.')
    else
        say('//ffxiai [status] | chat [on|off] | tells [on|off] | requests [on|off] | log [on|off]')
    end
end)

-- If the addon was loaded while already in game, 'load' has fired by the time this file finishes.
start()
