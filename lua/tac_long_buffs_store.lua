local store = {}

local function value(call)
    local result
    pcall(function() result = call() end)
    return result
end

local function identity(mq)
    local name = tostring(value(function() return mq.TLO.Me.CleanName() end) or '')
    local server = tostring(value(function() return mq.TLO.EverQuest.ServerName() end) or '')
    if server == '' then
        server = tostring(value(function() return mq.TLO.Zone.Server() end) or '')
    end
    local tag = (server .. '_' .. (name ~= '' and name or 'unknown')):gsub('[^%w%_-]', '_')
    return name, tag
end

function store.path(mq)
    local _, tag = identity(mq)
    return (mq.configDir or 'config') .. '/triune_long_buffs_' .. tag .. '.lua'
end

local function readTable(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    if ok and type(result) == 'table' then return result end
    return nil
end

local function legacyLoadout(mq)
    local name, tag = identity(mq)
    local dir = mq.configDir or 'config'
    local paths = {
        dir .. '/triune_loadout_' .. tag .. '.lua',
        dir .. '/triune_loadout.lua',
    }
    for _, path in ipairs(paths) do
        local data = readTable(path)
        local entry = data and (data[name] or data)
        local control = type(entry) == 'table' and entry.control or nil
        local plugin = type(control) == 'table' and control.plugins and control.plugins.long_buffs or nil
        local settings = type(plugin) == 'table' and plugin.settings or nil
        if type(settings) == 'table' then return settings end
    end
    return nil
end

local function quote(value)
    return string.format('%q', tostring(value or ''))
end

local function sortedMemberNames(members)
    local names = {}
    for name, value in pairs(type(members) == 'table' and members or {}) do
        if type(name) == 'string' and type(value) == 'table' then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

local function serialize(roster, minutes, bookCache, members, options)
    local out = { 'return { version = 2, minDurationMinutes = ', tostring(minutes),
        ', maxBuffs = ', tostring(math.floor(tonumber(options and options.maxBuffs) or 15)),
        ', autoSuggest = ', (options and options.autoSuggest == false) and 'false' or 'true',
        ', members = {' }
    for _, name in ipairs(sortedMemberNames(members)) do
        out[#out + 1] = '[' .. quote(name) .. ']={profile=' .. quote(members[name].profile)
            .. ',cats=' .. quote(members[name].cats) .. '},'
    end
    out[#out + 1] = '}, roster = {'
    for _, entry in ipairs(roster or {}) do
        out[#out + 1] = '{type=' .. quote(entry.type)
            .. ',name=' .. quote(entry.name)
            .. ',spellName=' .. quote(entry.spellName)
            .. ',class=' .. quote(entry.class)
            .. ',targetMode=' .. quote(entry.targetMode)
            .. ',scope=' .. quote(entry.scope)
            .. ',durationSec=' .. tostring(math.max(0, tonumber(entry.durationSec) or 0))
            .. '},'
    end
    out[#out + 1] = '}, bookCache = { checkedAt = '
        .. tostring(math.max(0, math.floor(tonumber(bookCache and bookCache.checkedAt) or 0)))
        .. ', spells = {'
    for _, name in ipairs(bookCache and bookCache.spells or {}) do
        if type(name) == 'string' and name ~= '' then
            out[#out + 1] = quote(name) .. ','
        end
    end
    out[#out + 1] = '} } }'
    return table.concat(out)
end

function store.load(mq, legacySettings)
    local path = store.path(mq)
    local saved = readTable(path) or readTable(path .. '.bak')
    if type(saved) == 'table' and type(saved.roster) == 'table' then
        return saved, false
    end

    local legacy = legacyLoadout(mq)
    if type(legacySettings) == 'table' and type(legacySettings.roster) == 'table' then
        legacy = legacySettings
    elseif not legacy then
        legacy = legacySettings
    end
    if type(legacy) == 'table' then
        local minutes = math.max(5, math.min(180, math.floor(tonumber(legacy.minDurationMinutes) or 15)))
        local roster = type(legacy.roster) == 'table' and legacy.roster or {}
        store.save(mq, roster, minutes)
        return { roster = roster, minDurationMinutes = minutes }, true
    end
    return { roster = {}, minDurationMinutes = 15 }, false
end

function store.loadBookCache(mq)
    local path = store.path(mq)
    local saved = readTable(path) or readTable(path .. '.bak')
    local cache = type(saved) == 'table' and saved.bookCache or nil
    if type(cache) ~= 'table' or type(cache.spells) ~= 'table' then return nil end
    return {
        spells = cache.spells,
        checkedAt = math.max(0, math.floor(tonumber(cache.checkedAt) or 0)),
    }
end

function store.save(mq, roster, minutes, bookCache, members, options)
    local path = store.path(mq)
    local previous = readTable(path) or readTable(path .. '.bak')
    local cache = bookCache or (type(previous) == 'table' and previous.bookCache) or {}
    if members == nil and type(previous) == 'table' then members = previous.members end
    if options == nil and type(previous) == 'table' then
        options = { maxBuffs = previous.maxBuffs, autoSuggest = previous.autoSuggest }
    end
    local body = serialize(roster, math.max(5, math.min(180, math.floor(tonumber(minutes) or 15))), cache, members, options)
    local suffix = tostring(os.time()) .. '_' .. tostring(math.floor((os.clock() % 1) * 1000000))
    local tmp, backup = path .. '.tmp_' .. suffix, path .. '.bak'
    local file, err = io.open(tmp, 'w')
    if not file then return false, err end
    local ok, writeErr = pcall(function()
        local wrote, err = file:write(body)
        if not wrote then error(err or 'write failed') end
    end)
    file:close()
    if not ok then
        os.remove(tmp)
        return false, writeErr
    end

    os.remove(backup)
    local hadPrevious = os.rename(path, backup)
    local moved, moveErr = os.rename(tmp, path)
    if not moved then
        if hadPrevious then os.rename(backup, path) end
        os.remove(tmp)
        return false, moveErr
    end
    os.remove(backup)
    return true
end

function store.saveBookCache(mq, spells, checkedAt)
    local settings = store.load(mq)
    return store.save(mq, settings.roster, settings.minDurationMinutes, {
        spells = spells,
        checkedAt = checkedAt,
    })
end

function store.signature(settings)
    local parts = { tostring(settings and settings.minDurationMinutes or 15),
        'o\31' .. tostring(settings and settings.maxBuffs or 15) .. '\31' .. tostring(settings and settings.autoSuggest) }
    for _, entry in ipairs(settings and settings.roster or {}) do
        parts[#parts + 1] = table.concat({
            tostring(entry.type or ''), tostring(entry.name or ''),
            tostring(entry.spellName or ''), tostring(entry.class or ''),
            tostring(entry.targetMode or ''), tostring(entry.scope or ''),
            tostring(entry.durationSec or 0),
        }, '\31')
    end
    for _, name in ipairs(sortedMemberNames(settings and settings.members)) do
        local m = settings.members[name]
        parts[#parts + 1] = 'm\31' .. name .. '\31' .. tostring(m.profile or '') .. '\31' .. tostring(m.cats or '')
    end
    return table.concat(parts, '\30')
end

function store.characterName(mq)
    return identity(mq)
end

return store
