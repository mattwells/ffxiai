--[[
Read-only tools for FFXI-AI. Each one reads this instance's game state through the Windower API and returns
a plain table, or nil and an error message. Nothing here sends anything to the game server.
]]

local res = require('resources')
local json = require('jsonx')

local tools = {}

-- Chat buffer, filled by the addon from 'chat message' events.
tools.chat = {}
tools.chat_max = 200
tools.settings = {chat = {enabled = false, tells = false}}

local EQUIP_SLOTS = {'main', 'sub', 'range', 'ammo', 'head', 'neck', 'left_ear', 'right_ear',
    'body', 'hands', 'left_ring', 'right_ring', 'back', 'waist', 'legs', 'feet'}

local extdata_ok, extdata = pcall(require, 'extdata')

local function round(n, places)
    local m = 10 ^ (places or 0)
    return math.floor(n * m + 0.5) / m
end

local function en(list, id)
    local r = list and id and list[id]
    return r and r.en or nil
end

local function player_or_err()
    local info = windower.ffxi.get_info()
    local player = info and info.logged_in and windower.ffxi.get_player()
    if not player then
        return nil, 'not logged in'
    end
    return player
end

local function job_string(player)
    local s = (player.main_job or '?') .. (player.main_job_level or '')
    if player.sub_job then
        s = s .. '/' .. player.sub_job .. (player.sub_job_level or '')
    end
    return s
end

local function mob_kind(mob)
    if mob.spawn_type == 16 then
        return 'monster'
    elseif mob.is_npc then
        return 'npc'
    end
    return 'player'
end

local function describe_mob(mob)
    if not mob then
        return nil
    end
    local t = {
        name = mob.name,
        type = mob_kind(mob),
        hp_percent = mob.hpp,
        distance = mob.distance and round(math.sqrt(mob.distance), 1) or nil,
        status = en(res.statuses, mob.status),
    }
    if mob.claim_id and mob.claim_id ~= 0 then
        local claimer = windower.ffxi.get_mob_by_id(mob.claim_id)
        t.claimed_by = claimer and claimer.name or 'someone'
    elseif t.type == 'monster' then
        t.claimed_by = json.null
    end
    return t
end

-- Short summary, used by list_characters.
function tools.summary()
    local info = windower.ffxi.get_info()
    local player = info and info.logged_in and windower.ffxi.get_player()
    if not player then
        return {logged_in = false}
    end
    return {
        logged_in = true,
        name = player.name,
        job = job_string(player),
        zone = en(res.zones, info.zone),
        status = en(res.statuses, player.status),
        hp_percent = player.vitals and player.vitals.hpp,
        mp_percent = player.vitals and player.vitals.mpp,
        tp = player.vitals and player.vitals.tp,
    }
end

function tools.get_player()
    local player, err = player_or_err()
    if not player then return nil, err end
    local v = player.vitals or {}
    local buffs = json.array()
    local timers = tools.buff_timers()
    for _, id in ipairs(player.buffs or {}) do
        if id ~= 255 then
            buffs[#buffs + 1] = {name = en(res.buffs, id) or ('buff ' .. id), seconds_left = timers(id)}
        end
    end
    local levels = json.object()
    for job, level in pairs(player.jobs or {}) do
        if type(level) == 'number' and level > 0 then
            levels[job] = level
        end
    end
    return {
        name = player.name,
        main_job = player.main_job_full or player.main_job,
        main_job_level = player.main_job_level,
        sub_job = player.sub_job_full or player.sub_job or json.null,
        sub_job_level = player.sub_job_level or json.null,
        job = job_string(player),
        hp = v.hp, max_hp = v.max_hp, hp_percent = v.hpp,
        mp = v.mp, max_mp = v.max_mp, mp_percent = v.mpp,
        tp = v.tp,
        status = en(res.statuses, player.status),
        buffs = buffs,
        job_levels = levels,
        nation = player.nation and ({[0] = "San d'Oria", [1] = 'Bastok', [2] = 'Windurst'})[player.nation] or nil,
        linkshell = player.linkshell ~= '' and player.linkshell or nil,
    }
end

function tools.get_target()
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local get = windower.ffxi.get_mob_by_target
    return {
        target = describe_mob(get('t')) or json.null,
        sub_target = describe_mob(get('st')) or json.null,
        battle_target = describe_mob(get('bt')) or json.null,
        pet = describe_mob(get('pet')) or json.null,
    }
end

function tools.get_party()
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local party = windower.ffxi.get_party() or {}
    local info = windower.ffxi.get_info() or {}
    local leaders = {
        [party.party1_leader or -1] = 'party', [party.party2_leader or -1] = 'party',
        [party.party3_leader or -1] = 'party', [party.alliance_leader or -1] = 'alliance',
    }
    local groups = {{'party', 'p'}, {'alliance_party_2', 'a1'}, {'alliance_party_3', 'a2'}}
    local out = json.object()
    for _, g in ipairs(groups) do
        local members = json.array()
        for i = 0, 5 do
            local m = party[g[2] .. i]
            if m and m.name then
                local id = m.id or (m.mob and m.mob.id)
                -- The server only sends HP/MP/TP for members in your zone; elsewhere they read as 0.
                -- A member Windower can see is here; otherwise go by zone, and an unknown zone isn't.
                local here = m.mob ~= nil or (m.zone ~= nil and m.zone == info.zone)
                local entry = {
                    name = m.name,
                    zone = en(res.zones, m.zone),
                    in_zone = here,
                    in_range = m.mob ~= nil,
                }
                if here then
                    entry.hp, entry.hp_percent = m.hp, m.hpp
                    entry.mp, entry.mp_percent = m.mp, m.mpp
                    entry.tp = m.tp
                else
                    entry.hp, entry.hp_percent = json.null, json.null
                    entry.mp, entry.mp_percent = json.null, json.null
                    entry.tp = json.null
                end
                if m.mob and m.mob.distance then
                    entry.distance = round(math.sqrt(m.mob.distance), 1)
                end
                if id and leaders[id] then
                    entry.leader = true
                end
                members[#members + 1] = entry
            end
        end
        if #members > 0 then
            out[g[1]] = members
        end
    end
    if not out.party then
        out.party = json.array()
    end
    return out
end

local function bag_list(which)
    which = which and which:lower():gsub('[%s_]', '') or 'inventory'
    local list = {}
    for id = 0, 17 do
        local bag = res.bags[id]
        if bag then
            local api = bag.api
            if which == 'all' or which == api or which == bag.en:lower():gsub('%s', '') then
                list[#list + 1] = bag
            end
        end
    end
    return list
end

-- The items in one bag from windower.ffxi.get_items(): for item in bag_items(contents) do ... end.
-- Skips disabled bags and empty slots.
local function bag_items(contents)
    local slot, max = 0, contents and contents.enabled ~= false and (contents.max or 80) or 0
    return function()
        while slot < max do
            slot = slot + 1
            local item = contents[slot]
            if type(item) == 'table' and item.id and item.id ~= 0 then
                return item
            end
        end
    end
end

local function bag_names()
    local names = {}
    for id = 0, 17 do
        if res.bags[id] then
            names[#names + 1] = res.bags[id].api
        end
    end
    return table.concat(names, ', ')
end

-- What Windower's extdata can tell about an item: augment strings, plus path and rank for items that
-- have them (Odyssey, Sortie and similar). Nil when there is nothing. Only data extdata decodes is used,
-- so nothing here needs updating when the game adds items.
local function item_details(item)
    if not (extdata_ok and item.extdata) then
        return nil
    end
    local ok, ext = pcall(extdata.decode, item)
    if not (ok and type(ext) == 'table') then
        return nil
    end
    local d = {}
    if type(ext.path) == 'string' then
        d.path = ext.path
        d.rank = type(ext.rank) == 'number' and ext.rank or nil
    end
    local augs = json.array()
    for _, a in ipairs(type(ext.augments) == 'table' and ext.augments or {}) do
        -- "System: 1 ID: n Val: n" is how extdata prints augment ids it has no name for;
        -- "Path: X" repeats the path field.
        if type(a) == 'string' and a ~= '' and a ~= 'none' and not a:find('^System: ')
                and not (d.path and a:find('^Path: ')) then
            augs[#augs + 1] = a
        end
    end
    d.augments = #augs > 0 and augs or nil
    if not (d.path or d.augments) then
        return nil
    end
    return d
end

local function can_have_augments(r)
    return r and (r.category == 'Weapon' or r.category == 'Armor')
end

-- Returns a function that tells whether a lowercased name matches the search text.
local function name_matcher(search, whole_word)
    if not whole_word then
        return function(s) return s:find(search, 1, true) ~= nil end
    end
    local pattern = search:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')
    if search:find('^%w') then pattern = '%f[%w]' .. pattern end
    if search:find('%w$') then pattern = pattern .. '%f[%W]' end
    return function(s) return s:find(pattern) ~= nil end
end

-- Storage slips: which item each bit of a slip stands for comes from Windower's res.slips, and the
-- slip's extdata has one bit set per item stored on it. Nothing here needs updating when slips change.
local slip_info

local function load_slip_info()
    local by_item = {}
    local ok, list = pcall(function() return res.slips end)
    if ok and type(list) == 'table' then
        for _, s in pairs(list) do
            if type(s) == 'table' and rawget(s, 'item_id') and type(rawget(s, 'items')) == 'table' then
                by_item[s.item_id] = {name = rawget(s, 'en') or ('Storage Slip ' .. s.id), number = s.id, items = s.items}
            end
        end
    end
    return by_item
end

-- Every slip the character carries: {name, bag, ids}, sorted by slip number, with ids in slip order.
local function stored_on_slips(items)
    slip_info = slip_info or load_slip_info()
    local out = {}
    for id = 0, 17 do
        local bag = res.bags[id]
        for item in bag_items(bag and items[bag.api]) do
            local slip = slip_info[item.id]
            if slip and type(item.extdata) == 'string' then
                local ids = {}
                for i = 1, #item.extdata do
                    local byte = item.extdata:byte(i)
                    for b = 0, 7 do
                        if math.floor(byte / 2 ^ b) % 2 == 1 then
                            local stored = slip.items[(i - 1) * 8 + b + 1]
                            if stored and stored ~= 0 then
                                ids[#ids + 1] = stored
                            end
                        end
                    end
                end
                out[#out + 1] = {name = slip.name, number = slip.number, bag = bag.en, ids = ids}
            end
        end
    end
    table.sort(out, function(a, b) return a.number < b.number end)
    return out
end

function tools.get_inventory(args)
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local search = type(args.search) == 'string' and args.search ~= '' and args.search:lower() or nil
    local whole_word = args.whole_word == true
    local matches = search and name_matcher(search, whole_word)
    local which = type(args.bag) == 'string' and args.bag or (search and 'all' or 'inventory')
    local norm = which:lower():gsub('[%s_]', '')
    local want_slips = norm == 'all' or norm == 'slips'
    local bags = norm == 'slips' and {} or bag_list(which)
    if #bags == 0 and not want_slips then
        return nil, 'unknown bag "' .. which .. '". Bags: all, slips, ' .. bag_names()
    end
    local items = windower.ffxi.get_items()
    if not items then
        return nil, 'inventory not loaded yet'
    end
    local out = {gil = items.gil, bags = json.array()}
    for _, bag in ipairs(bags) do
        local contents = items[bag.api]
        if contents and contents.enabled ~= false then
            local merged, order = {}, {}
            for item in bag_items(contents) do
                local r = res.items[item.id]
                local name = r and r.en or ('item ' .. item.id)
                local long = r and r.enl or name
                if not search or matches(name:lower()) or matches(long:lower()) then
                    -- Only identical copies share an entry: same item, same augments, and
                    -- equipped copies kept apart from spares.
                    local equipped = item.status == 5
                    local d = can_have_augments(r) and item_details(item) or {}
                    -- Built by hand: Windower's libs replace table.concat with one that
                    -- fails on json arrays (their metatable has no __index).
                    local key = item.id .. '|' .. (equipped and 'e' or '') .. '|' .. (d.path or '')
                        .. '|' .. (d.rank or '')
                    for _, a in ipairs(d.augments or {}) do
                        key = key .. '|' .. a
                    end
                    local m = merged[key]
                    if not m then
                        m = {name = name, count = 0, id = item.id, equipped = equipped or nil,
                            path = d.path, rank = d.rank, augments = d.augments}
                        merged[key] = m
                        order[#order + 1] = m
                    end
                    m.count = m.count + (item.count or 1)
                end
            end
            if not search or #order > 0 then
                out.bags[#out.bags + 1] = {
                    bag = bag.en,
                    used = contents.count,
                    max = contents.max,
                    items = json.array(order),
                }
            end
        end
    end
    if want_slips then
        for _, slip in ipairs(stored_on_slips(items)) do
            local list = json.array()
            for _, sid in ipairs(slip.ids) do
                local r = res.items[sid]
                local name = r and r.en or ('item ' .. sid)
                local long = r and r.enl or name
                if not search or matches(name:lower()) or matches(long:lower()) then
                    list[#list + 1] = {name = name, count = 1, id = sid}
                end
            end
            if not search or #list > 0 then
                out.bags[#out.bags + 1] = {
                    bag = slip.name,
                    slip_kept_in = slip.bag,
                    used = #slip.ids,
                    items = list,
                }
            end
        end
    end
    if search then
        out.search = search
        out.whole_word = whole_word
    end
    return out
end

-- Lookup: Windower resources ---------------------------------------------------------
-- Everything here reads Windower's res/ files, which Windower updates after game patches,
-- so the addon carries no game data of its own.

local LOOKUP_KINDS = {'item', 'spell', 'ability', 'weapon_skill', 'buff', 'key_item', 'job_trait', 'zone'}
local LOOKUP_RES = {
    item = 'items', spell = 'spells', ability = 'job_abilities', weapon_skill = 'weapon_skills',
    buff = 'buffs', key_item = 'key_items', job_trait = 'job_traits', zone = 'zones',
}

-- Resource bit fields (jobs, slots, targets, flags) arrive as Sets of values, or as raw numbers
-- if resources ever stops converting them. Returns the values (bit numbers for raw numbers).
local function set_values(v)
    local out = {}
    if type(v) == 'number' then
        local b = 0
        while v > 0 do
            if v % 2 == 1 then out[#out + 1] = b end
            v = math.floor(v / 2)
            b = b + 1
        end
    elseif type(v) == 'table' then
        for k, present in pairs(v) do
            if present == true then out[#out + 1] = k end
        end
        table.sort(out, function(a, b)
            if type(a) == 'number' and type(b) == 'number' then return a < b end
            return tostring(a) < tostring(b)
        end)
    end
    return out
end

local function job_list(jobs)
    local ids = set_values(jobs)
    local names, count = json.array(), 0
    for _, id in ipairs(ids) do
        local j = type(id) == 'number' and res.jobs[id]
        if j and id > 0 then
            names[#names + 1] = j.ens
            count = count + 1
        end
    end
    local all = 0
    for id = 1, 22 do
        if res.jobs[id] then all = all + 1 end
    end
    if count > 0 and count >= all then
        return 'All jobs'
    end
    table.sort(names)
    return names
end

local function name_list(values, list)
    local out = json.array()
    for _, v in ipairs(set_values(values)) do
        out[#out + 1] = type(v) == 'number' and en(list, v) or tostring(v)
    end
    return out
end

local function has_flag(flags, name)
    for _, f in ipairs(set_values(flags)) do
        if f == name then return true end
    end
    return false
end

local function spell_levels(levels)
    local out = json.object()
    for job, level in pairs(type(levels) == 'table' and levels or {}) do
        local j = res.jobs[job]
        out[j and j.ens or tostring(job)] = level
    end
    return out
end

local describe = {}

function describe.item(r)
    local d = res.item_descriptions[r.id]
    return {
        id = r.id, name = r.en,
        long_name = r.enl ~= r.en:lower() and r.enl or nil,
        category = r.category,
        level = r.level, item_level = r.item_level, superior_level = r.superior_level,
        jobs = r.jobs and job_list(r.jobs) or nil,
        slots = r.slots and #set_values(r.slots) > 0 and name_list(r.slots, res.slots) or nil,
        stack = r.stack,
        rare = has_flag(r.flags, 'Rare') or nil,
        exclusive = has_flag(r.flags, 'Exclusive') or nil,
        no_auction = has_flag(r.flags, 'No Auction') or nil,
        description = d and d.en or nil,
    }
end

function describe.spell(r)
    return {
        id = r.id, name = r.en, type = r.type,
        skill = en(res.skills, r.skill), element = en(res.elements, r.element),
        mp_cost = r.mp_cost, cast_time = r.cast_time, recast = r.recast,
        duration = r.duration, range = r.range,
        effect = r.status and en(res.buffs, r.status) or nil,
        targets = name_list(r.targets),
        levels = spell_levels(r.levels),
    }
end

function describe.ability(r)
    return {
        id = r.id, name = r.en, type = r.type,
        element = en(res.elements, r.element),
        mp_cost = r.mp_cost ~= 0 and r.mp_cost or nil, tp_cost = r.tp_cost ~= 0 and r.tp_cost or nil,
        duration = r.duration, range = r.range,
        effect = r.status and en(res.buffs, r.status) or nil,
        targets = name_list(r.targets),
    }
end

function describe.weapon_skill(r)
    local chain = json.array()
    for _, k in ipairs({'skillchain_a', 'skillchain_b', 'skillchain_c'}) do
        if r[k] and r[k] ~= '' then chain[#chain + 1] = r[k] end
    end
    return {
        id = r.id, name = r.en, skill = en(res.skills, r.skill),
        element = en(res.elements, r.element), range = r.range,
        skillchain = chain, targets = name_list(r.targets),
    }
end

function describe.buff(r)
    return {id = r.id, name = r.en, long_name = r.enl ~= r.en and r.enl or nil}
end

function describe.key_item(r)
    return {id = r.id, name = r.en, category = r.category}
end

function describe.job_trait(r)
    return {id = r.id, name = r.en}
end

function describe.zone(r)
    return {id = r.id, name = r.en, search_name = r.search}
end

-- What the character has, for owned = true: ids -> extra fields to add to each result.
local owned_of = {}

function owned_of.item()
    local items = windower.ffxi.get_items()
    if not items then
        return nil, 'inventory not loaded yet'
    end
    local have = {}
    for id = 0, 17 do
        local bag = res.bags[id]
        for item in bag_items(bag and items[bag.api]) do
            have[item.id] = have[item.id] or {counts = {}, order = {}}
            local h = have[item.id]
            if not h.counts[bag.en] then
                h.counts[bag.en] = 0
                h.order[#h.order + 1] = bag.en
            end
            h.counts[bag.en] = h.counts[bag.en] + (item.count or 1)
        end
    end
    for _, slip in ipairs(stored_on_slips(items)) do
        for _, sid in ipairs(slip.ids) do
            have[sid] = have[sid] or {counts = {}, order = {}}
            local h = have[sid]
            if not h.counts[slip.name] then
                h.counts[slip.name] = 0
                h.order[#h.order + 1] = slip.name
            end
            h.counts[slip.name] = h.counts[slip.name] + 1
        end
    end
    local out = {}
    for id, h in pairs(have) do
        local where = json.array()
        for _, b in ipairs(h.order) do
            where[#where + 1] = {bag = b, count = h.counts[b]}
        end
        out[id] = {owned_in = where}
    end
    return out
end

function owned_of.key_item()
    local out = {}
    for _, id in ipairs(windower.ffxi.get_key_items() or {}) do
        out[id] = {}
    end
    return out
end

function owned_of.spell()
    local out = {}
    for id, known in pairs(windower.ffxi.get_spells() or {}) do
        if known then out[id] = {} end
    end
    return out
end

local function usable_now(field)
    return function()
        local a = windower.ffxi.get_abilities() or {}
        local out = {}
        for _, id in ipairs(a[field] or {}) do
            out[id] = {}
        end
        return out
    end
end
owned_of.ability = usable_now('job_abilities')
owned_of.weapon_skill = usable_now('weapon_skills')

function tools.lookup(args)
    local kind = type(args.kind) == 'string' and args.kind:lower() or 'item'
    local res_name = LOOKUP_RES[kind]
    if not res_name then
        return nil, 'unknown kind "' .. kind .. '". Kinds: ' .. table.concat(LOOKUP_KINDS, ', ')
    end
    local name = type(args.name) == 'string' and args.name ~= '' and args.name:lower() or nil
    local text = type(args.text) == 'string' and args.text ~= '' and args.text:lower() or nil
    local id = tonumber(args.id)
    local owned = args.owned == true
    if text and kind ~= 'item' then
        return nil, '"text" searches item descriptions, so it only works with kind "item"'
    end
    if owned and not owned_of[kind] then
        return nil, '"owned" works with kinds item, key_item, spell, ability and weapon_skill'
    end
    if not (name or text or id or owned) then
        return nil, 'pass "name", "id" or "text" (or "owned": true)'
    end
    local have
    if owned then
        local _, err = player_or_err()
        if _ == nil then return nil, err end
        have, err = owned_of[kind]()
        if not have then return nil, err end
    end
    local limit = math.max(1, math.min(100, math.floor(tonumber(args.limit) or 20)))
    local matches = name and name_matcher(name, args.whole_word == true)
    local descriptions = text and res.item_descriptions

    local list = res[res_name]
    local found = {}
    local function consider(r)
        if type(r) ~= 'table' then return end
        local r_en, r_enl = rawget(r, 'en'), rawget(r, 'enl')
        if type(r_en) ~= 'string' or r_en == '' then return end
        if have and not have[r.id] then return end
        if name and not (matches(r_en:lower()) or (type(r_enl) == 'string' and matches(r_enl:lower()))) then return end
        if text then
            local d = descriptions[r.id]
            if not (d and d.en and d.en:lower():find(text, 1, true)) then return end
        end
        found[#found + 1] = r
    end
    if id then
        consider(rawget(list, id))
    else
        for _, r in pairs(list) do
            consider(r)
        end
    end
    -- Exact name matches first, then by id.
    table.sort(found, function(a, b)
        local ea, eb = name and a.en:lower() == name, name and b.en:lower() == name
        if ea ~= eb then return ea and true or false end
        return a.id < b.id
    end)

    local results = json.array()
    for i = 1, math.min(limit, #found) do
        -- A plain copy: resource entries fall back to the table library for missing fields,
        -- so r.range on an entry without one would be table.range.
        local r = {}
        for k, v in pairs(found[i]) do r[k] = v end
        local entry = describe[kind](r)
        for k, v in pairs(have and have[found[i].id] or {}) do
            entry[k] = v
        end
        results[#results + 1] = entry
    end
    return {
        kind = kind,
        results = results,
        total_matches = #found,
        note = #found > limit and ('Showing ' .. limit .. ' of ' .. #found .. '; narrow the search or raise "limit".') or nil,
    }
end

-- Merits, job points and currencies -------------------------------------------------
-- Field names come from Windower's packets library, so FFXI-AI has no list of its own to keep current.

local packets_ok, packets = pcall(require, 'packets')

-- Last parsed copy of the packets we read, with when they arrived.
-- 'points' = 0x063 type 2 (merit and limit points), 'capacity' = 0x063 type 5 (CP/JP per job),
-- 0x113 = Currencies, 0x118 = Currencies 2.
local seen = {}
local waiting_pages = {}

local function clock()
    return os.time()
end

-- Arrival time for packets Windower kept from before FFXI-AI loaded: unknown, so treated as old.
local KEPT = 0

-- Runs every waiting callback; one failing doesn't stop the rest (each still answers its caller).
local function run_callbacks(cbs)
    for _, cb in ipairs(cbs or {}) do
        local ok, e = pcall(cb)
        if not ok and windower.add_to_chat then
            pcall(windower.add_to_chat, 167, 'FFXI-AI: ' .. tostring(e))
        end
    end
end

local function fields_of(p)
    local out = {}
    for k, v in pairs(p) do
        if type(k) == 'string' and k:sub(1, 1) ~= '_' and (type(v) == 'number' or type(v) == 'boolean') then
            out[k] = v
        end
    end
    return out
end

-- The game data FFXI-AI reads from packets, by the names players know, in the order //ffxiai shows them.
tools.DATA_KINDS = {'Character stats', 'Skills', 'Buff timers', 'Merit points', 'Job points', 'Currencies', 'Currencies 2',
    'Quest and mission log'}

local function kind_of(id, data)
    if id == 0x061 then return 'Character stats' end
    if id == 0x062 then return 'Skills' end
    if id == 0x113 then return 'Currencies' end
    if id == 0x118 then return 'Currencies 2' end
    if id == 0x063 and type(data) == 'string' then
        local t = data:byte(5)
        if t == 0x02 then return 'Merit points' end
        if t == 0x05 then return 'Job points' end
        if t == 0x09 then return 'Buff timers' end
    end
end

-- Little-endian unsigned 32-bit number at a 1-based byte position.
local function u32(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not d then return nil end
    return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

-- Buff timers in 0x063 type 9 count in 1/60 s of the game's own clock. The player update packet (0x037)
-- carries that clock, which gives the offset to real time (the same way GearSwap does it).
local game_clock_offset

local function note_game_clock(data)
    local a, b = u32(data, 0x41), u32(data, 0x3D)
    if a and b then
        game_clock_offset = os.time() - ((a * 60 - b) % 0x100000000) / 60
    end
end

-- Treasure pool, from the drop (0x0D2) and lot (0x0D3) packets: pool slot -> what we know about it.
local treasure = {}

local function note_treasure(id, p)
    local slot = p['Index']
    if slot == nil then return end
    if id == 0x0D2 then
        treasure[slot] = {item = p['Item'], dropped = clock(), old = p['Old'] and true or false}
    else
        local t = treasure[slot] or {}
        treasure[slot] = t
        if p['Drop'] and p['Drop'] ~= 0 then
            treasure[slot] = nil
            return
        end
        local lot = p['Highest Lot']
        if lot and lot > 0 and lot ~= 0xFFFF then
            t.highest_lot, t.highest_lotter = lot, p['Highest Lotter Name']
        end
    end
end

-- What arrived, for checking on it: kind -> {time, error}. Shown by //ffxiai and in tool output when
-- something is missing.
tools.packets_seen = {}

local function note_packet(kind, t, err)
    tools.packets_seen[kind] = {time = t, error = err}
end

-- Called with every incoming packet (and with Windower's last copies at load, with source set).
function tools.record_packet(id, data, source)
    if id == 0x037 then
        if type(data) == 'string' then note_game_clock(data) end
        return
    end
    -- Puppetmaster's job packet (0x044 for job 18, main job only): the automaton's name, HP/MP, skills and stats.
    if id == 0x044 then
        if packets_ok and type(data) == 'string' and data:byte(5) == 18 and data:byte(6) == 0 then
            local ok, p = pcall(packets.parse, 'incoming', data)
            if ok and type(p) == 'table' then seen.automaton = {time = source and KEPT or clock(), packet = p} end
        end
        return
    end
    -- Quest and mission log (0x056): the game sends one packet per part (type in bytes 0x25-0x26) on zone-in.
    -- Each part is kept as raw bytes and decoded by get_missions.
    if id == 0x056 then
        if type(data) ~= 'string' or #data < 0x26 then return end
        local part = data:byte(0x25) + data:byte(0x26) * 0x100
        local t = source and KEPT or clock()
        seen.mission_log = seen.mission_log or {}
        seen.mission_log[part] = {time = t, data = data}
        note_packet('Quest and mission log', t)
        return
    end
    if (id == 0x0D2 or id == 0x0D3) and not source then
        if not packets_ok then return end
        local ok, p = pcall(packets.parse, 'incoming', data)
        if ok and type(p) == 'table' then note_treasure(id, p) end
        return
    end
    local kind = kind_of(id, data)
    if not kind then return end
    -- A copy Windower kept from before this load has no known arrival time: KEPT marks it, so it
    -- is never shown as current and counts as stale for requests.
    local t = source and KEPT or clock()
    if not packets_ok then return note_packet(kind, t, "Windower's packets library didn't load") end
    local ok, p = pcall(packets.parse, 'incoming', data)
    if not ok or type(p) ~= 'table' then
        return note_packet(kind, t, "couldn't be read: " .. tostring(p))
    end
    note_packet(kind, t)
    if id == 0x063 then
        local kind = data:byte(5)
        if kind == 0x02 then
            seen.points = {time = t, fields = fields_of(p)}
        elseif kind == 0x05 then
            seen.capacity = {time = t, packet = p}
        elseif kind == 0x09 then
            -- 32 buff slots: ids at 0x09, timers at 0x49 (1-based), as GearSwap reads them.
            local list = {}
            for i = 1, 32 do
                local lo, hi = data:byte(i * 2 + 7, i * 2 + 8)
                local buff = lo and hi and lo + hi * 0x100
                if buff and buff ~= 0 and buff ~= 255 then
                    list[#list + 1] = {id = buff, raw = u32(data, i * 4 + 0x45)}
                end
            end
            seen.buffs = {time = t, list = list}
        end
        return
    end
    if id == 0x061 or id == 0x062 then
        seen[id] = {time = t, packet = p}
        return
    end
    seen[id] = {time = t, fields = fields_of(p)}
    local w = waiting_pages
    if not source and w.pages and w.pages[id] then
        w.pages[id] = nil
        if next(w.pages) == nil then
            waiting_pages = {}
            run_callbacks(w.callbacks)
        end
    end
end

-- Fills the cache from the last packets Windower kept, so a reload doesn't start empty.
function tools.seed_packets()
    local last = windower.packets and windower.packets.last_incoming
    if not last then return end
    for _, id in ipairs({0x037, 0x044, 0x056, 0x061, 0x062, 0x063, 0x113, 0x118}) do
        local ok, data = pcall(last, id)
        if ok and data then
            tools.record_packet(id, data, 'kept by Windower')
        end
    end
end

-- "12 seconds ago" (or "12s ago" when short) for a time in epoch seconds; nil for nil.
local UNITS = {long = {' seconds ago', ' minutes ago', ' hours ago'}, short = {'s ago', 'm ago', 'h ago'}}

local function age_text(t, short)
    if not t then return nil end
    if t == KEPT then return 'before FFXI-AI was last loaded' end
    local u = short and UNITS.short or UNITS.long
    local s = math.max(0, os.difftime(clock(), t))
    if s < 60 then return math.floor(s) .. u[1] end
    if s < 3600 then return math.floor(s / 60) .. u[2] end
    return math.floor(s / 3600) .. u[3]
end
tools.age_text = age_text

-- kind -> "received 12s ago[, error]" or "not received yet", for tool output and //ffxiai.
function tools.packets_summary()
    local out = json.object()
    for _, kind in ipairs(tools.DATA_KINDS) do
        local s = tools.packets_seen[kind]
        out[kind] = s and ((s.time == KEPT and 'received at an unknown time' or ('received ' .. age_text(s.time, true)))
            .. (s.error and (', but ' .. s.error) or '')) or 'not received yet'
    end
    return out
end

local function jp_key(job)
    return job and job.ens and job.ens:lower()
end

function tools.get_merits(args)
    local player, err = player_or_err()
    if not player then return nil, err end
    local out = {}

    -- Merits spent: Windower's player data, name -> level. Only the ones with points in them.
    local merits = json.object()
    for name, level in pairs(player.merits or {}) do
        if type(level) == 'number' and level > 0 then
            merits[tostring(name)] = level
        end
    end
    out.merits = merits

    local pts = seen.points
    if pts then
        local f = pts.fields
        out.merit_points = {
            available = f['Merit Points'], max = f['Max Merit Points'], limit_points = f['Limit Points'],
            limit_point_mode = f['Limit Point Mode'], as_of = age_text(pts.time),
        }
    else
        out.merit_points = {not_seen_yet = 'The game sends these when you zone or gain limit points; '
            .. 'they show up here after that.', packets_seen = tools.packets_summary()}
    end

    -- Job points: per job, capacity points and job points (from the game's points packet) and the
    -- categories with points spent (Windower's player data).
    local which = type(args.job) == 'string' and args.job ~= '' and args.job:upper() or nil
    if which then
        local known = false
        for id = 1, 22 do
            if res.jobs[id] and res.jobs[id].ens == which then known = true end
        end
        if not known then
            return nil, 'unknown job "' .. args.job .. '" (use the three-letter name, e.g. DNC)'
        end
    end
    local cap = seen.capacity and seen.capacity.packet
    local jobs = json.object()
    for id = 1, 22 do
        local job = res.jobs[id]
        if job and (not which or job.ens == which) then
            local entry = {}
            if cap then
                local name = job.en
                entry.capacity_points = cap[name .. ' Capacity Points']
                entry.job_points = cap[name .. ' Job Points']
                entry.job_points_spent = cap[name .. ' Spent Job Points']
            end
            local spent = (player.job_points or {})[jp_key(job)]
            if type(spent) == 'table' then
                local cats = json.object()
                for k, v in pairs(spent) do
                    if type(v) == 'number' and v > 0 and k ~= 'cp' and k ~= 'jp' and k ~= 'jp_spent' then
                        cats[tostring(k)] = v
                    end
                end
                if next(cats) then entry.categories = cats end
                entry.capacity_points = entry.capacity_points or spent.cp
                entry.job_points = entry.job_points or spent.jp
                entry.job_points_spent = entry.job_points_spent or spent.jp_spent
            end
            if next(entry) then
                jobs[job.ens] = entry
            elseif which then
                jobs[job.ens] = {not_seen_yet = 'No job point data for this job yet.'}
            end
        end
    end
    out.job_points = jobs
    out.job_points_as_of = seen.capacity and age_text(seen.capacity.time) or nil
    out.note = 'Merit and limit points update whenever the game sends them (gaining points, zoning). '
        .. 'Job point categories are levels (0 to 20).'
    return out
end

-- Returns a function giving seconds left on the next buff with that id (in player.buffs order), or nil
-- when the game hasn't sent a timer for it.
function tools.buff_timers()
    local list = seen.buffs and seen.buffs.list or {}
    local used = {}
    return function(id)
        for i, b in ipairs(list) do
            if not used[i] and b.id == id then
                used[i] = true
                if not (game_clock_offset and b.raw) then return nil end
                local left = b.raw / 60 + game_clock_offset - os.time()
                -- Buffs without a real timer come out far in the future or in the past.
                return left > 0 and left < 86400 and math.floor(left) or nil
            end
        end
    end
end

local function not_seen(what)
    return {not_seen_yet = 'The game sends ' .. what .. ' when you log in or zone, and when it changes; '
        .. 'it shows up here after that.', packets_seen = tools.packets_summary()}
end

function tools.get_skills()
    local player, err = player_or_err()
    if not player then return nil, err end
    local s = seen[0x062]
    -- Automaton skills aren't in the skills packet; get_job_setup has them.
    local groups = {Combat = 'combat', Magic = 'magic', Synthesis = 'crafting'}
    local out = {}
    for _, key in pairs(groups) do out[key] = json.object() end
    for id = 1, 63 do
        local r = res.skills[id]
        local key = type(r) == 'table' and groups[rawget(r, 'category')]
        if key then
            local entry
            if s then
                local p = s.packet
                local level = p[r.en .. ' Level']
                if type(level) == 'number' and level > 0 then
                    entry = {level = level, capped = p[r.en .. ' Capped'] and true or false}
                    local rank = p[r.en .. ' Rank']
                    if key == 'crafting' and type(rank) == 'number' then
                        entry.rank = en(res.synth_ranks, rank)
                    end
                end
            else
                -- Without the packet, Windower's player data still has the levels.
                local level = (player.skills or {})[r.en:lower():gsub('[%s%-]', '_')]
                if type(level) == 'number' and level > 0 then
                    entry = {level = level}
                end
            end
            out[key][r.en] = entry
        end
    end
    out.as_of = s and age_text(s.time) or nil
    out.note = 'Combat and magic skills are for the current jobs; "capped" means at the cap for the current level.'
        .. (s and '' or ' Caps and craft ranks show up once the game sends the skills packet (on login or zoning).')
    return out
end

function tools.get_stats()
    local player, err = player_or_err()
    if not player then return nil, err end
    local s = seen[0x061]
    if not s then return not_seen('character stats') end
    local p = s.packet
    local stats = json.object()
    for _, k in ipairs({'STR', 'DEX', 'VIT', 'AGI', 'INT', 'MND', 'CHR'}) do
        local base, added = p['Base ' .. k] or 0, p['Added ' .. k] or 0
        stats[k] = {base = base, added = added, total = base + added}
    end
    local resist = json.object()
    for _, e in ipairs({'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark'}) do
        resist[e] = p[e .. ' Resistance']
    end
    local out = {
        stats = stats,
        attack = p['Attack'], defense = p['Defense'],
        elemental_resistance = resist,
        -- At 99 the game keeps sending a full EXP bar that means nothing; limit points are in get_merits.
        exp = (player.main_job_level or 0) < 99 and {current = p['Current EXP'], to_next_level = p['Required EXP']} or nil,
        master_level = p['Master Level'],
        master_breaker = p['Master Breaker'] and true or false,
        exemplar_points = {current = p['Current Exemplar Points'], to_next_level = p['Required Exemplar Points']},
        title = en(res.titles, p['Title']),
        nation_rank = p['Nation rank'],
        rank_points = p['Rank points'],
        home_point = en(res.zones, p['Home point']),
        unity = {rank = p['Unity Rank'], points = p['Unity Points']},
        as_of = age_text(s.time),
        note = 'Attack, defense and stats are as the game last sent them, with current gear and buffs. '
            .. 'Limit and merit points are in get_merits.',
    }
    return out
end

-- Automaton parts are items in Windower's resources, at their id or 0x2000 above it.
local function automaton_part(id)
    if type(id) ~= 'number' or id == 0 then return nil end
    for _, i in ipairs({id, id + 0x2000}) do
        local r = res.items[i]
        if r and r.category == 'Automaton' then return r.en end
    end
    return 'part ' .. id
end

local function job_setup(job_id, data, is_main)
    if type(data) ~= 'table' then return nil end
    if job_id == 16 then
        local spells = json.array()
        for _, id in pairs(data.spells or {}) do
            local name = type(id) == 'number' and id > 0 and en(res.spells, id)
            if name then spells[#spells + 1] = name end
        end
        table.sort(spells)
        return {blue_magic_set = spells}
    elseif job_id == 18 then
        local parts = json.array()
        for _, id in pairs(data.attachments or {}) do
            local name = automaton_part(id)
            if name then parts[#parts + 1] = name end
        end
        table.sort(parts)
        local out = {head = automaton_part(data.head), frame = automaton_part(data.frame), attachments = parts}
        local a = seen.automaton
        if not is_main then
            -- Only main job Puppetmaster gets the automaton details.
        elseif a then
            local p = a.packet
            local name = type(p['Pet Name']) == 'string' and p['Pet Name']:gsub('%z.*', '') or ''
            local skill = function(k)
                return {level = p['Current ' .. k .. ' Skill'], max = p['Max ' .. k .. ' Skill']}
            end
            local stats = json.object()
            for _, k in ipairs({'STR', 'DEX', 'VIT', 'AGI', 'INT', 'MND', 'CHR'}) do
                local base, added = p['Base ' .. k] or 0, p['Additional ' .. k] or 0
                stats[k] = {base = base, added = added, total = base + added}
            end
            out.automaton = {
                name = name ~= '' and name or nil,
                hp = p['Current HP'], max_hp = p['Max HP'], mp = p['Current MP'], max_mp = p['Max MP'],
                skills = {melee = skill('Melee'), ranged = skill('Ranged'), magic = skill('Magic')},
                stats = stats,
                as_of = age_text(a.time),
            }
        else
            out.automaton = {not_seen_yet = 'The game sends the automaton\'s name, skills and stats when you zone, '
                .. 'change job or use a maneuver; they show up here after that.'}
        end
        return out
    elseif job_id == 23 then
        return {species = en(res.monstrosity, data.species)}
    end
end

function tools.get_job_setup()
    local player, err = player_or_err()
    if not player then return nil, err end
    local f = windower.ffxi
    local out = {
        main_job = player.main_job,
        main = job_setup(player.main_job_id, f.get_mjob_data and f.get_mjob_data(), true) or json.null,
    }
    if player.sub_job_id and f.get_sjob_data then
        out.sub_job = player.sub_job
        out.sub = job_setup(player.sub_job_id, f.get_sjob_data()) or json.null
    end
    out.note = 'Only Blue Mage (spells set), Puppetmaster (automaton) and Monstrosity have a setup to show.'
    return out
end

local POOL_SECONDS = 300

function tools.get_treasure_pool()
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local items = windower.ffxi.get_items() or {}
    local pool = json.array()
    local now = clock()
    local present = {}
    for slot, it in pairs(items.treasure or {}) do
        local id = type(it) == 'table' and (it.item_id or it.id)
        if id and id ~= 0 then
            present[slot] = true
            local entry = {name = en(res.items, id) or ('item ' .. id)}
            local t = treasure[slot]
            if t and t.item == id then
                if t.dropped and not t.old then
                    entry.seconds_left = math.max(0, POOL_SECONDS - math.floor(os.difftime(now, t.dropped)))
                end
                entry.highest_lot = t.highest_lot
                entry.highest_lotter = t.highest_lotter
            end
            pool[#pool + 1] = entry
        end
    end
    for slot in pairs(treasure) do
        if not present[slot] then treasure[slot] = nil end
    end
    return {
        items = pool,
        note = 'Time left and lots are only known for drops seen while FFXI-AI was loaded. Items stay in the pool '
            .. 'for about 5 minutes.',
    }
end

local NEARBY_KINDS = {monster = true, player = true, npc = true, all = true}

function tools.get_nearby(args)
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local kind = type(args.kind) == 'string' and args.kind:lower() or 'monster'
    if not NEARBY_KINDS[kind] then
        return nil, 'unknown kind "' .. tostring(args.kind) .. '" (monster, player, npc or all)'
    end
    local search = type(args.name) == 'string' and args.name ~= '' and args.name:lower() or nil
    local max_distance = tonumber(args.max_distance) or 50
    local limit = math.max(1, math.min(100, math.floor(tonumber(args.limit) or 20)))
    local me = windower.ffxi.get_mob_by_target('me')
    local found = {}
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if type(m) == 'table' and m.valid_target and m.name and m.name ~= '' and m.distance
                and not (me and m.id == me.id)
                and (kind == 'all' or mob_kind(m) == kind)
                and (not search or m.name:lower():find(search, 1, true))
                and math.sqrt(m.distance) <= max_distance then
            found[#found + 1] = m
        end
    end
    table.sort(found, function(a, b) return a.distance < b.distance end)
    local list = json.array()
    for i = 1, math.min(limit, #found) do
        list[i] = describe_mob(found[i])
    end
    return {
        found = #found,
        shown = list,
        note = #found > limit and ('Showing the nearest ' .. limit .. '; raise "limit" or narrow it down to see more.') or nil,
    }
end

local CURRENCY_PAGES = {[0x113] = 'Currencies', [0x118] = 'Currencies 2'}
local FRESH = 30 -- seconds a requested page counts as current
local REQUEST_FOR = {[0x113] = 0x10F, [0x118] = 0x115} -- page -> the outgoing request for it

local function currency_result(search)
    local out = {pages = json.array()}
    local missing = {}
    for _, id in ipairs({0x113, 0x118}) do
        local page = seen[id]
        if page then
            local values = json.object()
            for k, v in pairs(page.fields) do
                if not search or k:lower():find(search, 1, true) then
                    values[k] = v
                end
            end
            if not search or next(values) then
                out.pages[#out.pages + 1] = {page = CURRENCY_PAGES[id], as_of = age_text(page.time), values = values}
            end
        else
            missing[#missing + 1] = CURRENCY_PAGES[id]
        end
    end
    if #missing > 0 then
        out.not_read = missing
        out.packets_seen = tools.packets_summary()
        out.note = tools.settings.requests
            and 'The game did not answer for these pages. Try again in a moment.'
            or ('Not seen yet. Open those menus in game (Menu > Profile > Currencies, and Currencies 2), or let FFXI-AI ask the game '
                .. 'for them itself with //ffxiai requests on.')
    end
    out.requests = tools.settings.requests and 'on' or 'off'
    return out
end

function tools.get_currencies(args)
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local search = type(args.search) == 'string' and args.search ~= '' and args.search:lower() or nil
    local stale = {}
    for id in pairs(CURRENCY_PAGES) do
        if not seen[id] or os.difftime(clock(), seen[id].time) > FRESH then
            stale[id] = true
        end
    end
    -- Sending anything to the game server is off unless the player turned it on (//ffxiai requests on).
    if not (tools.settings.requests and packets_ok and next(stale)) then
        return currency_result(search)
    end
    return function(done)
        local finish = function() done(currency_result(search)) end
        local w = waiting_pages
        if w.pages then
            -- Join the request in flight, asking for any page this call needs that it didn't.
            table.insert(w.callbacks, finish)
            for id in pairs(stale) do
                if not w.requested[id] then
                    w.requested[id], w.pages[id] = true, true
                    packets.inject(packets.new('outgoing', REQUEST_FOR[id], {}))
                end
            end
            return
        end
        w = {pages = {}, requested = {}, callbacks = {finish}}
        waiting_pages = w
        for id in pairs(stale) do
            w.pages[id], w.requested[id] = true, true
            -- The same requests the game sends when the Currencies menus are opened.
            packets.inject(packets.new('outgoing', REQUEST_FOR[id], {}))
        end
        coroutine.schedule(function()
            if waiting_pages == w then
                waiting_pages = {}
                run_callbacks(w.callbacks)
            end
        end, 2)
    end
end

-- Missions ------------------------------------------------------------------------------

local missions_ok, mission_names = pcall(require, 'missions')
if not missions_ok or type(mission_names) ~= 'table' then mission_names = {} end

-- Parts of the mission log packet (0x056) that get_missions reads.
local LOG_CURRENT, LOG_TVR, LOG_TOAU_WOTG = 0xFFFF, 0xFFFE, 0x0080
local LOG_DONE_NATIONS, LOG_DONE_TOAU_WOTG = 0x00D0, 0x00D8

-- Storylines in story order. 'flags' storylines have a completed list (one bit per mission id, at byte
-- 'done_at' of part 'done'); 'linear' ones only send the current mission, so everything before it is done.
-- 'value' reads the current mission from the packet parts. 'final' is a last mission that stays current
-- for good once reached, so reaching it means finished. 'hidden' ids are internal steps, not missions.
-- Decoding rules follow Chronicle's notes (see missions.lua).
local NATION_KEYS = {[0] = 'sandoria', [1] = 'bastok', [2] = 'windurst'}

local function u8(data, pos) return data:byte(pos) end

local NATION_HIDDEN = {[6] = true, [7] = true, [8] = true, [9] = true} -- alternate destinations of mission 5

local MISSION_LINES = {
    {key = 'sandoria', name = "San d'Oria", kind = 'flags', done = LOG_DONE_NATIONS, done_at = 5, hidden = NATION_HIDDEN},
    {key = 'bastok', name = 'Bastok', kind = 'flags', done = LOG_DONE_NATIONS, done_at = 13, hidden = NATION_HIDDEN},
    {key = 'windurst', name = 'Windurst', kind = 'flags', done = LOG_DONE_NATIONS, done_at = 21, hidden = NATION_HIDDEN},
    {key = 'zilart', name = 'Rise of the Zilart', kind = 'flags', done = LOG_DONE_NATIONS, done_at = 29,
        value = function(p) return p[LOG_CURRENT] and u32(p[LOG_CURRENT], 13) end,
        hidden = {[2] = true}},
    {key = 'cop', name = 'Chains of Promathia', kind = 'linear', final = 850,
        value = function(p) return p[LOG_CURRENT] and u32(p[LOG_CURRENT], 17) end,
        hidden = {[101] = true, [137] = true, [257] = true, [330] = true, [331] = true, [335] = true, [339] = true,
            [340] = true, [341] = true, [345] = true, [349] = true, [367] = true, [447] = true, [540] = true,
            [542] = true, [543] = true, [546] = true, [549] = true, [550] = true, [552] = true, [553] = true,
            [556] = true, [559] = true, [560] = true, [562] = true, [564] = true, [577] = true, [647] = true,
            [758] = true}},
    {key = 'toau', name = 'Treasures of Aht Urhgan', kind = 'flags', done = LOG_DONE_TOAU_WOTG, done_at = 5, final = 47,
        value = function(p) return p[LOG_TOAU_WOTG] and u32(p[LOG_TOAU_WOTG], 25) end},
    {key = 'wotg', name = 'Wings of the Goddess', kind = 'flags', done = LOG_DONE_TOAU_WOTG, done_at = 13,
        value = function(p) return p[LOG_TOAU_WOTG] and u32(p[LOG_TOAU_WOTG], 29) end,
        hidden = {[53] = true}},
    {key = 'acp', name = 'A Crystalline Prophecy', kind = 'linear', final = 11,
        value = function(p) return p[LOG_CURRENT] and u8(p[LOG_CURRENT], 25) % 16 end},
    {key = 'mkd', name = "A Moogle Kupo d'Etat", kind = 'linear', final = 14,
        value = function(p) return p[LOG_CURRENT] and math.floor(u8(p[LOG_CURRENT], 25) / 16) end},
    {key = 'asa', name = 'A Shantotto Ascension', kind = 'linear', final = 14,
        value = function(p) return p[LOG_CURRENT] and u8(p[LOG_CURRENT], 26) % 16 end},
    {key = 'soa', name = 'Seekers of Adoulin', kind = 'linear', final = 368, hidden = {[999] = true},
        value = function(p) return p[LOG_CURRENT] and u32(p[LOG_CURRENT], 29) end},
    {key = 'rov', name = "Rhapsodies of Vana'diel", kind = 'linear', final = 334,
        value = function(p) return p[LOG_CURRENT] and u32(p[LOG_CURRENT], 33) end},
    -- TVR is the only storyline still getting new missions, so only it checks for one newer than the table.
    {key = 'tvr', name = 'The Voracious Resurgence', kind = 'linear', final = 642, between_flag = true, newer_margin = 4,
        value = function(p) return p[LOG_TVR] and u32(p[LOG_TVR], 5) end},
}

-- A linear storyline's value can sit a little above its mission's id: Chronicle saw 454 for TVR mission 452,
-- and finished Adoulin and Rhapsodies send 374 and 340 for their last missions (368, 334). Finished TVR sends
-- exactly 642. A TVR value more than newer_margin above its last mission is probably a newer mission.
local NONE = 0xFFFF -- "no current mission" in the 32-bit fields

-- Mission ids of a storyline in story order, without hidden steps.
local function line_ids(line)
    local ids = {}
    for id in pairs(mission_names[line.key] or {}) do
        if not (line.hidden and line.hidden[id]) then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

local function bit_set(data, from, id)
    local b = data and data:byte(from + math.floor(id / 8))
    return b ~= nil and math.floor(b / 2 ^ (id % 8)) % 2 == 1
end

local function lookup_hint(line, after)
    return 'Not in FFXI-AI\'s mission table, probably newer than it. Only if you need the name, look it up on '
        .. 'BG-Wiki (the ' .. line.name .. ' missions page' .. (after and (', the mission after "' .. after .. '"') or '')
        .. '); don\'t guess it.'
end

local function mission_name(line, id)
    return (mission_names[line.key] or {})[id]
end

-- One storyline's state: {status, current, completed, total, missions (with list), ...}.
local function decode_line(line, parts, nation, with_list)
    local ids = line_ids(line)
    local out = {storyline = line.name}
    local status_of = {} -- id -> 'completed' | 'current' | 'next'
    local unknown
    if line.kind == 'flags' then
        local done = parts[line.done] and parts[line.done].data
        local current
        if NATION_KEYS[nation] == line.key and parts[LOG_CURRENT] then
            current = u32(parts[LOG_CURRENT].data, 9)
        elseif line.value then
            local p = {}
            for k, v in pairs(parts) do p[k] = v.data end
            current = line.value(p)
        end
        if not done and current == nil then return nil end
        -- No mission, or a hidden placeholder (e.g. Goddess's "Lest We Forget" once it's finished).
        -- (The nations' hidden 6-9 are real missions you can be on, just folded into 5 in lists.)
        if current and (current >= NONE
            or (line.hidden and line.hidden ~= NATION_HIDDEN and line.hidden[current])) then current = false end
        for _, id in ipairs(ids) do
            if done and bit_set(done, line.done_at, id) then status_of[id] = 'completed' end
        end
        if line.hidden == NATION_HIDDEN and done then
            -- Mission 5 counts as done when any of its alternate destinations (6-9) is.
            for sub = 6, 9 do
                if bit_set(done, line.done_at, sub) then status_of[5] = 'completed' end
            end
        end
        if line.key == 'zilart' then
            -- The Last Verse (31) completes with Chains of Promathia's end.
            local cop = parts[LOG_CURRENT] and u32(parts[LOG_CURRENT].data, 17)
            if cop and cop >= 850 and cop < NONE then status_of[31] = 'completed' end
        end
        if current then
            if line.final == current then
                status_of[current] = 'completed'
            elseif status_of[current] ~= 'completed' then
                status_of[current] = 'current'
            end
            if not mission_name(line, current) then
                unknown = {current_id = current, note = lookup_hint(line)}
            end
        end
        -- Completed flags for ids the table doesn't have.
        if done then
            local extra = {}
            local names = mission_names[line.key] or {}
            for id = 0, 63 do
                if bit_set(done, line.done_at, id) and names[id] == nil and not (line.hidden and line.hidden[id]) then
                    extra[#extra + 1] = id
                end
            end
            if #extra > 0 then
                unknown = unknown or {}
                unknown.completed_ids = extra
                unknown.note = lookup_hint(line)
            end
        end
        out.current = current and status_of[current] == 'current' and (mission_name(line, current) or ('mission id ' .. current)) or nil
    else
        local p = {}
        for k, v in pairs(parts) do p[k] = v.data end
        local raw = line.value(p)
        if raw == nil then return nil end
        out.raw = raw
        local value, between = raw, false
        if line.between_flag and raw >= 0x80000000 then
            -- TVR only: top bit set means no mission in progress; the rest points at the next one.
            value, between = raw - 0x80000000, true
        end
        local active
        for i = #ids, 1, -1 do
            if ids[i] <= value then active = ids[i]; break end
        end
        if value == 0 or not active then
            out.status = 'not started'
        else
            local last = ids[#ids]
            for _, id in ipairs(ids) do
                if id < active then status_of[id] = 'completed' end
            end
            if active == last and line.newer_margin and value - last > line.newer_margin then
                status_of[active] = 'completed'
                unknown = {after = mission_name(line, last), note = lookup_hint(line, mission_name(line, last))}
                out.status = 'on a mission newer than FFXI-AI\'s table'
            elseif between then
                status_of[active] = 'next'
                out.status = 'between missions'
                out.next = mission_name(line, active)
            elseif line.final == active then
                status_of[active] = 'completed'
                out.status = 'finished'
            else
                status_of[active] = 'current'
                out.current = mission_name(line, active)
            end
        end
    end
    local completed = 0
    for _, id in ipairs(ids) do
        if status_of[id] == 'completed' then completed = completed + 1 end
    end
    out.completed = completed
    out.total = #ids
    if not out.status then
        if out.current then
            out.status = 'in progress'
        elseif completed == #ids and #ids > 0 then
            out.status = 'finished'
        elseif completed > 0 then
            out.status = 'between missions'
        else
            out.status = 'not started'
        end
    end
    out.not_in_table = unknown
    if with_list then
        local list = json.array()
        for _, id in ipairs(ids) do
            list[#list + 1] = {name = mission_name(line, id), status = status_of[id] or 'not done'}
        end
        out.missions = list
    end
    return out
end

local function find_line(text)
    text = text:lower():gsub("[^%w']", '')
    for _, line in ipairs(MISSION_LINES) do
        local name = line.name:lower():gsub("[^%w']", '')
        if line.key == text or name:find(text, 1, true) then return line end
    end
end

local LOG_PART_NAMES = {[LOG_CURRENT] = 'current missions', [LOG_TVR] = 'Voracious Resurgence',
    [LOG_TOAU_WOTG] = 'Aht Urhgan and Goddess current', [LOG_DONE_NATIONS] = 'nation and Zilart completed',
    [LOG_DONE_TOAU_WOTG] = 'Aht Urhgan and Goddess completed'}

function tools.get_missions(args)
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local parts = seen.mission_log or {}
    local only
    if type(args.storyline) == 'string' and args.storyline ~= '' then
        only = find_line(args.storyline)
        if not only then
            local names = {}
            for _, line in ipairs(MISSION_LINES) do names[#names + 1] = line.name end
            return nil, 'no storyline matches "' .. args.storyline .. '". Storylines: ' .. table.concat(names, ', ')
        end
    end
    local nation = parts[LOG_CURRENT] and u32(parts[LOG_CURRENT].data, 5)
    local out = {nation = ({[0] = "San d'Oria", [1] = 'Bastok', [2] = 'Windurst'})[nation]}
    local list = json.array()
    for _, line in ipairs(MISSION_LINES) do
        if not only or only == line then
            local d = decode_line(line, parts, nation, only ~= nil)
            if d then
                -- Leave out the other nations' storylines unless something in them is done.
                if not (NATION_KEYS[0] == line.key or NATION_KEYS[1] == line.key or NATION_KEYS[2] == line.key)
                    or NATION_KEYS[nation] == line.key or d.completed > 0 or only then
                    list[#list + 1] = d
                end
            end
        end
    end
    out.storylines = list
    local received, missing = json.object(), {}
    for part, label in pairs(LOG_PART_NAMES) do
        if parts[part] then
            received[label] = parts[part].time == KEPT and 'before FFXI-AI was last loaded' or age_text(parts[part].time)
        else
            missing[#missing + 1] = label
        end
    end
    out.received = received
    if #missing > 0 then
        table.sort(missing)
        out.not_received = missing
        out.note = 'The game sends the mission log when the character zones. Zone once (any zone line, warp or '
            .. 'teleport) with FFXI-AI loaded to fill in the rest.'
    end
    return out
end

-- Quests -------------------------------------------------------------------------------

local quests_ok, quest_names = pcall(require, 'quests')
if not quests_ok or type(quest_names) ~= 'table' then quest_names = {} end

-- Quest areas as the game's quest log groups them: the 0x056 part with the "current" bits and the one with
-- the "completed" bits (one bit per quest id, from byte 5). Special cases follow Chronicle's notes:
-- 'hidden' ids are placeholders in the game data, 'gone' quests can no longer be done (shown only if done),
-- 'either' folds quests where only one of a group can be done into the first one, and 'final' quests stay
-- current for good once reached, so current there means done.
local QUEST_AREAS = {
    {key = 'sandoria', name = "San d'Oria", current = 0x0050, done = 0x0090, either = {[75] = {76}}},
    {key = 'bastok', name = 'Bastok', current = 0x0058, done = 0x0098},
    {key = 'windurst', name = 'Windurst', current = 0x0060, done = 0x00A0,
        hidden = {[22] = true, [54] = true, [55] = true, [56] = true, [57] = true, [58] = true, [59] = true, [99] = true}},
    -- 180-185 (Jeuno) and 106, 107, 112, 113 (Adoulin) get set inside quest chains but have no entry at all in
    -- the game's quest name DATs (0xD99D, 0xD9BB; checked 2026-11-08), so they are progress flags, not quests.
    {key = 'jeuno', name = 'Jeuno', current = 0x0068, done = 0x00A8,
        hidden = {[122] = true, [125] = true, [126] = true, [127] = true,
            [180] = true, [181] = true, [182] = true, [183] = true, [184] = true, [185] = true},
        gone = {[33] = true, [34] = true, [35] = true, [36] = true, [37] = true, [38] = true, [39] = true, [40] = true}},
    -- Mog Garden quests (1039-1049) are listed here but tracked in Adoulin's bits, at id - 1000.
    {key = 'other', name = 'Other Areas', current = 0x0070, done = 0x00B0, either = {[24] = {10}},
        elsewhere = {from = 1000, current = 0x00F0, done = 0x00F8}},
    {key = 'outlands', name = 'Outlands', current = 0x0078, done = 0x00B8, gone = {[128] = true}},
    -- Aht Urhgan's quest bits are the first 16 bytes of parts that also carry mission data.
    {key = 'toau', name = 'Aht Urhgan', current = 0x0080, done = 0x00C0, bits = 128},
    -- Crystal War's bits past 127 are dense and unrelated to the table (its quests stop at 98), so they look
    -- like other data; only the first 128 are read for quests the table doesn't name.
    {key = 'wotg', name = 'Crystal War', current = 0x0088, done = 0x00C8, either = {[69] = {70, 71}},
        gone = {[31] = true}, final = {[98] = true}, bits = 128},
    {key = 'abyssea', name = 'Abyssea', current = 0x00E0, done = 0x00E8, final = {[186] = true}},
    {key = 'adoulin', name = 'Adoulin', current = 0x00F0, done = 0x00F8,
        hidden = {[106] = true, [107] = true, [112] = true, [113] = true}},
    {key = 'coalition', name = 'Coalition', current = 0x0100, done = 0x0108, hidden = {[47] = true},
        gone = {[16] = true, [17] = true, [18] = true, [19] = true, [20] = true}},
}

local QUEST_STATUSES = {completed = true, ['in progress'] = true, ['not done'] = true, ['no longer available'] = true}

-- Every quest in an area with its status, in id order, plus ids with bits set that the table doesn't have.
local function decode_quest_area(area, parts)
    local cur = parts[area.current] and parts[area.current].data
    local done = parts[area.done] and parts[area.done].data
    if not cur and not done then return nil end
    local names = quest_names[area.key] or {}
    local folded = {}
    for _, others in pairs(area.either or {}) do
        for _, o in ipairs(others) do folded[o] = true end
    end
    local function flags(id)
        local c, d = cur, done
        local bit_id = id
        if area.elsewhere and id >= area.elsewhere.from then
            c = parts[area.elsewhere.current] and parts[area.elsewhere.current].data
            d = parts[area.elsewhere.done] and parts[area.elsewhere.done].data
            bit_id = id - area.elsewhere.from
        end
        return bit_set(d, 5, bit_id), bit_set(c, 5, bit_id)
    end
    local ids = {}
    for id in pairs(names) do
        if not (area.hidden and area.hidden[id]) and not folded[id] then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local list = {}
    for _, id in ipairs(ids) do
        local is_done, is_current = flags(id)
        for _, o in ipairs((area.either or {})[id] or {}) do
            local od, oc = flags(o)
            is_done, is_current = is_done or od, is_current or oc
        end
        local status
        if is_done or (is_current and area.final and area.final[id]) then
            status = 'completed' -- (current bits stay set after a quest is done, so done wins)
        elseif area.gone and area.gone[id] then
            status = 'no longer available'
        elseif is_current then
            status = 'in progress'
        else
            status = 'not done'
        end
        list[#list + 1] = {name = names[id], status = status}
    end
    -- Bits another area reads as its own quests (Other Areas' Mog Garden quests in Adoulin's bits).
    local lent = {}
    for _, other in ipairs(QUEST_AREAS) do
        local e = other.elsewhere
        if e and e.done == area.done then
            for id in pairs(quest_names[other.key] or {}) do
                if id >= e.from then lent[id - e.from] = true end
            end
        end
    end
    local unknown = {}
    for id = 0, (area.bits or 256) - 1 do
        if names[id] == nil and not lent[id] and not (area.hidden and area.hidden[id])
            and (bit_set(done, 5, id) or bit_set(cur, 5, id)) then
            unknown[#unknown + 1] = id
        end
    end
    return list, unknown
end

local function find_quest_area(text)
    local t = text:lower():gsub("[^%w']", '')
    for _, area in ipairs(QUEST_AREAS) do
        local name = area.name:lower():gsub("[^%w']", '')
        if area.key == t or name:find(t, 1, true) then return area end
    end
end

function tools.get_quests(args)
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local parts = seen.mission_log or {}
    local only
    if type(args.area) == 'string' and args.area ~= '' then
        only = find_quest_area(args.area)
        if not only then
            local names = {}
            for _, area in ipairs(QUEST_AREAS) do names[#names + 1] = area.name end
            return nil, 'no quest area matches "' .. args.area .. '". Areas: ' .. table.concat(names, ', ')
        end
    end
    local want = type(args.status) == 'string' and args.status ~= '' and args.status:lower() or nil
    if want and not QUEST_STATUSES[want] then
        return nil, 'status must be one of: completed, in progress, not done, no longer available'
    end
    local search = type(args.search) == 'string' and args.search ~= '' and args.search:lower() or nil
    local show_list = only or want or search
    local out = {areas = json.array()}
    local missing = {}
    for _, area in ipairs(QUEST_AREAS) do
        if not only or only == area then
            local list, unknown = decode_quest_area(area, parts)
            if not list then
                missing[#missing + 1] = area.name
            else
                local counts = {completed = 0, ['in progress'] = 0, ['not done'] = 0, ['no longer available'] = 0}
                local in_progress, shown = json.array(), json.array()
                for _, q in ipairs(list) do
                    counts[q.status] = counts[q.status] + 1
                    if q.status == 'in progress' then in_progress[#in_progress + 1] = q.name end
                    if show_list and (not want or q.status == want)
                        and (not search or q.name:lower():find(search, 1, true)) then
                        shown[#shown + 1] = q
                    end
                end
                local entry = {area = area.name, completed = counts.completed, in_progress = counts['in progress'],
                    not_done = counts['not done'], total = #list - counts['no longer available']}
                if show_list then
                    entry.quests = shown
                else
                    entry.in_progress_quests = in_progress
                end
                if #unknown > 0 then
                    entry.not_in_table = {ids = unknown, note = 'Flags the game set that FFXI-AI\'s table doesn\'t name: '
                        .. 'quests newer than the table, or progress flags inside a quest chain that have no name at all. '
                        .. 'Only if you need them, look them up on BG-Wiki (' .. area.name .. ' quests); don\'t guess names.'}
                end
                -- With a search, leave out areas with no matches.
                if not search or #shown > 0 then out.areas[#out.areas + 1] = entry end
            end
        end
    end
    if #missing > 0 then
        out.not_received = missing
        out.note = 'The game sends the quest log when the character zones. Zone once (any zone line, warp or '
            .. 'teleport) with FFXI-AI loaded to fill in the rest.'
    end
    out.counting = '"total" leaves out quests that can no longer be done. A quest the game still lists as current '
        .. 'after it was done counts as completed.'
    return out
end

function tools.get_equipment()
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local items = windower.ffxi.get_items()
    local equipment = items and items.equipment
    if not equipment then
        return nil, 'equipment not loaded yet'
    end
    local out = json.object()
    for _, slot in ipairs(EQUIP_SLOTS) do
        local index, bag = equipment[slot], equipment[slot .. '_bag']
        local item = index and index ~= 0 and windower.ffxi.get_items(bag, index)
        if item and item.id and item.id ~= 0 then
            local d = item_details(item) or {}
            out[slot] = {
                name = en(res.items, item.id) or ('item ' .. item.id),
                bag = en(res.bags, bag),
                path = d.path,
                rank = d.rank,
                augments = d.augments,
            }
        else
            out[slot] = json.null
        end
    end
    return out
end

function tools.get_recasts()
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    local abilities = json.array()
    for id, seconds in pairs(windower.ffxi.get_ability_recasts() or {}) do
        if seconds and seconds > 0 then
            abilities[#abilities + 1] = {name = en(res.ability_recasts, id) or ('ability ' .. id), seconds = round(seconds)}
        end
    end
    local spells = json.array()
    for id, frames in pairs(windower.ffxi.get_spell_recasts() or {}) do
        if frames and frames > 0 then
            spells[#spells + 1] = {name = en(res.spells, id) or ('spell ' .. id), seconds = round(frames / 60, 1)}
        end
    end
    table.sort(abilities, function(a, b) return a.seconds < b.seconds end)
    table.sort(spells, function(a, b) return a.seconds < b.seconds end)
    return {
        abilities_on_cooldown = abilities,
        spells_on_cooldown = spells,
        note = 'Anything not listed is ready.',
    }
end

function tools.get_location()
    local info = windower.ffxi.get_info()
    if not info or not info.logged_in then
        return nil, 'not logged in'
    end
    local me = windower.ffxi.get_mob_by_target('me')
    local minutes = info.time or 0
    return {
        zone = en(res.zones, info.zone),
        in_mog_house = info.mog_house or false,
        weather = en(res.weather, info.weather),
        game_time = string.format('%02d:%02d', math.floor(minutes / 60) % 24, math.floor(minutes % 60)),
        game_day = en(res.days, info.day),
        moon = info.moon and (info.moon .. '%') or nil,
        moon_phase = en(res.moon_phases, info.moon_phase),
        position = me and {x = round(me.x, 1), y = round(me.y, 1), z = round(me.z, 1)} or nil,
        server = en(res.servers, info.server),
    }
end

function tools.get_chat(args)
    local _, err = player_or_err()
    if _ == nil then return nil, err end
    if not tools.settings.chat.enabled then
        return nil, 'chat reading is turned off for this character (in game: //ffxiai chat on)'
    end
    local limit = tonumber(args.limit) or 50
    limit = math.max(1, math.min(tools.chat_max, math.floor(limit)))
    local channel = type(args.channel) == 'string' and args.channel ~= '' and args.channel:lower() or nil
    local lines = json.array()
    for i = #tools.chat, 1, -1 do
        local line = tools.chat[i]
        if not channel or line.channel == channel then
            table.insert(lines, 1, line)
            if #lines >= limit then
                break
            end
        end
    end
    return {
        lines = lines,
        tells_included = tools.settings.chat.tells and true or false,
        note = 'Only chat received while the addon was loaded is available.',
    }
end

-- Called from the 'chat message' event.
function tools.record_chat(message, sender, mode)
    if not tools.settings.chat.enabled then
        return
    end
    local channel = en(res.chat, mode) or ('mode ' .. tostring(mode))
    if channel == 'tell' and not tools.settings.chat.tells then
        return
    end
    local text = message or ''
    if windower.convert_auto_trans then
        local ok, converted = pcall(windower.convert_auto_trans, text)
        if ok and converted then text = converted end
    end
    -- Strip colour codes and auto-translate brackets while the text is still Shift-JIS.
    text = text:gsub('[\30\31\127].', ''):gsub('\239[\39\40]', '')
    if windower.from_shift_jis then
        local ok, converted = pcall(windower.from_shift_jis, text)
        if ok and converted then text = converted end
    end
    tools.chat[#tools.chat + 1] = {time = os.date('%H:%M:%S'), channel = channel, sender = sender, text = text}
    while #tools.chat > tools.chat_max do
        table.remove(tools.chat, 1)
    end
end

-- Dispatch ---------------------------------------------------------------------------

local handlers = {
    summary = tools.summary,
    get_player = tools.get_player,
    get_target = tools.get_target,
    get_party = tools.get_party,
    get_inventory = tools.get_inventory,
    get_equipment = tools.get_equipment,
    get_recasts = tools.get_recasts,
    get_location = tools.get_location,
    get_chat = tools.get_chat,
    lookup = tools.lookup,
    get_merits = tools.get_merits,
    get_currencies = tools.get_currencies,
    get_skills = tools.get_skills,
    get_stats = tools.get_stats,
    get_job_setup = tools.get_job_setup,
    get_treasure_pool = tools.get_treasure_pool,
    get_nearby = tools.get_nearby,
    get_missions = tools.get_missions,
    get_quests = tools.get_quests,
}

function tools.run(name, args)
    local fn = handlers[name]
    if not fn then
        return nil, 'unknown tool ' .. tostring(name) .. ' (that character may be running a different version of FFXI-AI)'
    end
    return fn(type(args) == 'table' and args or {})
end

return tools
