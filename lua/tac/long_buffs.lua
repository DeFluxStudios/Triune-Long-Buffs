---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- ============================================================================
-- TAC/lua/tac/long_buffs.lua — Long-Duration Class Buffs Plugin
-- ============================================================================
-- Uses class spell data plus the character's scribed spells and trained class
-- AAs. TAC casts use its guarded downtime path; the standalone host provides
-- equivalent safe-idle checks and restores temporary gem swaps.
-- ============================================================================

local plugin = {
    id                 = 'long_buffs',
    name               = 'Long-Duration Buffs',
    version            = '1.10.0',
    author             = 'Triune',
    description        = 'Casts scribed class buffs and trained class AAs with long-duration beneficial effects on self and group.',
    defaultEnabled     = true,
    tickInterval       = 0.5,
    runOutOfCombatOnly = true,
    hasThread          = false,
}

local sharedStore = require('tac_long_buffs_store')
local core, ctrl, mq, runtime, DATA, ImGui = nil, nil, nil, nil, nil, nil
local cfg = {
    enabled = false,
    forceBreak = true,
    gatherGroup = true,
    debug = false,
    minDurationMinutes = 15,
    roster = {},
    members = {},
    maxBuffs = 15,
    autoSuggest = true,
}

-- The book TLO can return empty/nil entries between valid slots; readBookName
-- treats those as holes and the scan continues through the full indexed range.
local BOOK_SLOT_MAX = 1120
local BOOK_SLOTS_PER_TICK = 120
local BOOK_CACHE_REFRESH_SEC = 15 * 60
local RETRY_SEC = 15
local SUGGESTED_ROSTER_SIZE = 15 -- default
local ROSTER_USER_MAX = 40       -- highest value the user can choose
local ROSTER_HARD_MAX = 60       -- internal ceiling; raise later for more buff slots

local state = {
    scanning = false,
    complete = false,
    cursor = 1,
    nextScanAt = 0,
    bookNames = {},
    catalog = {},
    spellCount = 0,
    aaCount = 0,
    candidateCursor = 1,
    targetCursor = 1,
    nextQueryAt = 0,
    lastStackQueryError = nil,
    noSwapGem = false,
    discoveryRequested = false,
    refreshRequested = false,
    proposal = nil,
    proposalOpen = false,
    proposalOpened = false,
    stackUnknownCount = 0,
    stackConflictCount = 0,
    duplicateCount = 0,
    status = '',
    nextSharedPollAt = 0,
    sharedSignature = nil,
    bookCacheCheckedAt = 0,
    bookCacheValid = false,
}

local attempted = {}
local attemptCounts = {}
-- State of the forced rebuff break (see plugin.onBetweenPulls).
local brk = { active = false, since = 0, medding = false, cooldownUntil = 0, finishUntil = nil, paused = {}, gatherAt = 0 }
local BREAK_MAX_SEC = 240
local BREAK_COOLDOWN_SEC = 600
local BREAK_MED_START_PCT = 40
local BREAK_MED_STOP_PCT = 80
local BREAK_MAX_ATTEMPTS = 3
local BREAK_NAV_TIMEOUT_SEC = 25

-- Verbose debug log: queued in memory and appended to
-- <MacroQuest>/logs/triune_long_buffs_<character>.log about once a second.
local dbg = { queue = {}, once = {}, path = nil, nextFlushAt = 0, nextSnapshotAt = 0 }
local DEBUG_LOG_MAX_BYTES = 2 * 1024 * 1024

local function dlog(fmt, ...)
    if not cfg.debug then return end
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then line = tostring(fmt) end
    dbg.queue[#dbg.queue + 1] = os.date('%H:%M:%S') .. '  ' .. line
    if #dbg.queue > 500 then table.remove(dbg.queue, 1) end
end

-- Logs a message only when it differs from the last one for that key.
local function dlogChange(key, fmt, ...)
    if not cfg.debug then return end
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then line = tostring(fmt) end
    if dbg.once[key] == line then return end
    dbg.once[key] = line
    dlog('%s', line)
end

local function debugLogPath()
    if dbg.path then return dbg.path end
    local dir
    pcall(function() dir = tostring(mq.TLO.MacroQuest.Path('logs')() or '') end)
    if not dir or dir == '' or dir == 'NULL' then
        dir = (tostring(mq.configDir or 'config'):gsub('[\\/]+[^\\/]*$', '')) .. '/logs'
    end
    local character = 'unknown'
    pcall(function() character = tostring(mq.TLO.Me.CleanName() or 'unknown') end)
    dbg.path = dir .. '/triune_long_buffs_' .. character .. '.log'
    return dbg.path
end

local function flushDebugLog(force)
    if #dbg.queue == 0 or not mq then return end
    if not force and os.clock() < dbg.nextFlushAt then return end
    dbg.nextFlushAt = os.clock() + 1
    local path = debugLogPath()
    local handle = io.open(path, 'a')
    if not handle then
        dbg.queue = {}
        cfg.debug = false
        print('\ar[Long Buffs]\ax Could not open ' .. path .. '; debug logging turned off.')
        return
    end
    handle:write(table.concat(dbg.queue, '\n'), '\n')
    local size = handle:seek('end')
    handle:close()
    dbg.queue = {}
    if size and size > DEBUG_LOG_MAX_BYTES then
        os.remove(path .. '.old')
        os.rename(path, path .. '.old')
    end
end
local scribeEventName = nil

local function refresh()
    ctrl = core and core.ctrl
    mq = core and core.mq
    runtime = core and core.runtime
    DATA = core and core.DATA
    ImGui = core and core.ImGui
end

local function cleanName(name)
    if type(name) ~= 'string' then return '' end
    local result = name:match('^%s*(.-)%s*$') or ''
    if core and core.cleanSpellName then
        local ok, cleaned = pcall(core.cleanSpellName, result)
        if ok and type(cleaned) == 'string' and cleaned ~= '' then result = cleaned end
    end
    return result
end

local function nameKey(name)
    return cleanName(name):lower()
end

local function classRows(classMap, className)
    if type(classMap) ~= 'table' or type(className) ~= 'string' then return nil end
    if type(classMap[className]) == 'table' then return classMap[className] end
    local wanted = className:upper()
    for key, rows in pairs(classMap) do
        if type(key) == 'string' and key:upper() == wanted and type(rows) == 'table' then
            return rows
        end
    end
    return nil
end

local function classNames()
    local out = {}
    local seen = {}
    for _, name in ipairs(core and core.myClasses or {}) do
        if type(name) == 'string' and name ~= '' and not seen[name:upper()] then
            seen[name:upper()] = true
            out[#out + 1] = name
        end
    end
    return out
end

local function classSignature(classes, level)
    table.sort(classes)
    local character = ''
    pcall(function() character = tostring(mq.TLO.Me.CleanName() or '') end)
    return character .. ':' .. table.concat(classes, '/') .. ':' .. tostring(level)
end

local function beginScan(signature)
    state.scanning = true
    state.complete = false
    state.cursor = 1
    state.signature = signature
    state.bookNames = {}
    state.catalog = {}
    state.spellCount = 0
    state.aaCount = 0
    state.candidateCursor = 1
    state.targetCursor = 1
    state.nextQueryAt = 0
    state.lastStackQueryError = nil
    state.noSwapGem = false
    state.bookCacheValid = false
    attempted = {}
    attemptCounts = {}
end

local function cachedBookNames(cache)
    local names = {}
    for _, name in ipairs(type(cache) == 'table' and cache.spells or {}) do
        local key = nameKey(name)
        if key ~= '' then names[key] = cleanName(name) end
    end
    return names
end

local function saveBookCache()
    if not mq then return false end
    local names = {}
    for _, name in pairs(state.bookNames) do names[#names + 1] = name end
    table.sort(names)
    local ok, err = sharedStore.saveBookCache(mq, names, state.bookCacheCheckedAt)
    if not ok then
        state.status = 'Could not save the scribed-spell cache: ' .. tostring(err)
    end
    return ok
end

local function loadBookCache()
    local cache = mq and sharedStore.loadBookCache(mq)
    if not cache or cache.checkedAt <= 0 then return false end
    local age = os.time() - cache.checkedAt
    if age < 0 or age >= BOOK_CACHE_REFRESH_SEC then return false end
    state.bookNames = cachedBookNames(cache)
    state.bookCacheCheckedAt = cache.checkedAt
    state.bookCacheValid = true
    state.nextScanAt = os.clock() + (BOOK_CACHE_REFRESH_SEC - age)
    return true
end

local function normalizedRoster(entries)
    local roster, seen = {}, {}
    for _, entry in ipairs(type(entries) == 'table' and entries or {}) do
        if type(entry) == 'table'
            and (entry.type == 'spell' or entry.type == 'aa')
            and type(entry.name) == 'string' and entry.name ~= ''
            and type(entry.spellName) == 'string' and entry.spellName ~= '' then
            local key = nameKey(entry.spellName)
            if key ~= '' and not seen[key] then
                seen[key] = true
                roster[#roster + 1] = {
                    type = entry.type,
                    name = cleanName(entry.name),
                    spellName = cleanName(entry.spellName),
                    class = cleanName(entry.class or ''),
                    targetMode = entry.targetMode == 'self' and 'self'
                        or (entry.targetMode == 'group' and 'group' or 'single'),
                    scope = entry.scope == 'self' and 'self' or 'group',
                    durationSec = math.max(0, tonumber(entry.durationSec) or 0),
                }
            end
        end
    end
    return roster
end

local resetAudience, audienceMembers, spellCategories

local function normalizedMembers(members)
    local out = {}
    local valid = { auto = true, melee = true, hybrid = true, caster = true, all = true, custom = true }
    for name, value in pairs(type(members) == 'table' and members or {}) do
        if type(name) == 'string' and name ~= '' and type(value) == 'table' then
            local profile = valid[value.profile] and value.profile or 'auto'
            if profile ~= 'auto' then
                local cats = {}
                for key in tostring(value.cats or ''):gmatch('[%a]+') do cats[#cats + 1] = key end
                out[name] = { profile = profile, cats = table.concat(cats, ',') }
            end
        end
    end
    return out
end

local function sharedSettings()
    return {
        roster = normalizedRoster(cfg.roster),
        minDurationMinutes = cfg.minDurationMinutes,
        members = normalizedMembers(cfg.members),
        maxBuffs = math.max(1, math.min(ROSTER_USER_MAX, math.floor(tonumber(cfg.maxBuffs) or 15))),
        autoSuggest = cfg.autoSuggest ~= false,
    }
end

local function persistSharedSettings()
    if not mq then return end
    local settings = sharedSettings()
    local signature = sharedStore.signature(settings)
    if signature == state.sharedSignature then return end
    local ok, err = sharedStore.save(mq, settings.roster, settings.minDurationMinutes, nil, settings.members,
        { maxBuffs = settings.maxBuffs, autoSuggest = settings.autoSuggest })
    if ok then
        state.sharedSignature = signature
    else
        state.status = 'Could not save the shared long-buff roster: ' .. tostring(err)
    end
end

local function pollSharedSettings()
    if not mq or os.clock() < (state.nextSharedPollAt or 0) then return end
    state.nextSharedPollAt = os.clock() + 2
    local settings = sharedStore.load(mq)
    local signature = sharedStore.signature(settings)
    if signature ~= state.sharedSignature then
        state.sharedSignature = signature
        cfg.roster = normalizedRoster(settings.roster)
        cfg.members = normalizedMembers(settings.members)
        if tonumber(settings.maxBuffs) then
            cfg.maxBuffs = math.max(1, math.min(ROSTER_USER_MAX, math.floor(tonumber(settings.maxBuffs))))
        end
        if settings.autoSuggest ~= nil then cfg.autoSuggest = settings.autoSuggest == true end
        resetAudience()
        cfg.minDurationMinutes = math.max(5, math.min(180,
            math.floor(tonumber(settings.minDurationMinutes) or cfg.minDurationMinutes)))
        state.candidateCursor, state.targetCursor = 1, 1
        if cfg.enabled then beginScan(nil) end
    end
end

local function readBookName(slotIndex)
    local name = nil
    pcall(function()
        local bookSlot = mq.TLO.Me.Book(slotIndex)
        local value = bookSlot and bookSlot()
        if type(value) == 'string' and value ~= '' and value ~= 'NULL' then
            name = value
        end
    end)
    return name
end

local function readDurationSeconds(spell)
    if not spell or not core or not core.parseDurationSec then return 0 end
    local seconds = 0
    pcall(function() seconds = tonumber(core.parseDurationSec(spell.Duration)) or 0 end)
    if seconds <= 0 then
        pcall(function() seconds = tonumber(core.parseDurationSec(spell.MyDuration)) or 0 end)
    end
    return seconds
end

local function readSpellFacts(name)
    local spell = nil
    pcall(function()
        spell = mq.TLO.Spell(name)
        if not spell or not spell() then spell = nil end
    end)
    if not spell then return nil end

    local beneficial = false
    local duration = 0
    local level = 0
    local targetType = ''
    pcall(function() beneficial = spell.Beneficial() == true end)
    if not beneficial then return nil end
    duration = readDurationSeconds(spell)
    if duration < cfg.minDurationMinutes * 60 then return nil end
    pcall(function() level = tonumber(spell.Level()) or 0 end)
    pcall(function() targetType = tostring(spell.TargetType() or ''):lower() end)

    local targetMode = 'single'
    if targetType:find('self', 1, true)
        and not targetType:find('group', 1, true)
        and not targetType:find('area', 1, true)
        and not targetType:find('ae', 1, true) then
        targetMode = 'self'
    elseif targetType:find('group', 1, true)
        or targetType:find('area', 1, true)
        or targetType:find('ae', 1, true) then
        targetMode = 'group'
    end

    return {
        spellName = name,
        durationSec = duration,
        level = level,
        targetMode = targetMode,
    }
end

local function bookHasSpell(bookNames, name)
    local key = nameKey(name)
    return key ~= '' and bookNames[key] ~= nil
end

local function addSpellCandidates(candidates, bookNames, classes, playerLevel)
    local byName = {}
    local spellLists = DATA and DATA.spells
    if type(spellLists) ~= 'table' then return end

    for _, className in ipairs(classes) do
        local rows = classRows(spellLists, className)
        for _, row in ipairs(rows or {}) do
            local name = type(row) == 'table' and cleanName(row[1]) or ''
            local level = type(row) == 'table' and (tonumber(row[2]) or 1) or 1
            local beneficial = type(row) == 'table' and (row[3] == 1 or row[3] == true)
            local kind = type(row) == 'table' and tostring(row[4] or ''):lower() or ''
            if name ~= '' and level <= playerLevel and beneficial and kind == 'buff' and bookHasSpell(bookNames, name) then
                local key = nameKey(name)
                local existing = byName[key]
                if not existing or level > existing.classLevel then
                    local facts = readSpellFacts(name)
                    if facts then
                        byName[key] = {
                            type = 'spell',
                            name = name,
                            spellName = facts.spellName,
                            class = className,
                            classLevel = level,
                            levelScore = facts.level > 0 and facts.level or level,
                            durationSec = facts.durationSec,
                            targetMode = facts.targetMode,
                        }
                    end
                end
            end
        end
    end

    for _, candidate in pairs(byName) do
        candidates[#candidates + 1] = candidate
    end
end

local function aaNameFromRow(row)
    if type(row) == 'string' then return cleanName(row) end
    if type(row) == 'table' then return cleanName(row[1] or row.name or '') end
    return ''
end

local function addAACandidates(candidates, classes, playerLevel)
    local aaLists = DATA and DATA.aas
    if type(aaLists) ~= 'table' then return end
    local seen = {}

    for _, className in ipairs(classes) do
        local rows = classRows(aaLists, className)
        for _, row in ipairs(rows or {}) do
            local name = aaNameFromRow(row)
            local key = nameKey(name)
            if key ~= '' and not seen[key] then
                seen[key] = true
                local aa = nil
                pcall(function()
                    aa = mq.TLO.Me.AltAbility(name)
                    if not aa or not aa() or (tonumber(aa.Rank()) or 0) <= 0 then aa = nil end
                end)
                if aa then
                    local aaSpell = nil
                    local spellName = nil
                    pcall(function()
                        aaSpell = aa.Spell
                        if aaSpell and aaSpell() then spellName = cleanName(aaSpell.Name()) end
                    end)
                    if spellName and spellName ~= '' then
                        local facts = readSpellFacts(spellName)
                        if facts then
                            local rank = 0
                            pcall(function() rank = tonumber(aa.Rank()) or 0 end)
                            candidates[#candidates + 1] = {
                                type = 'aa',
                                name = name,
                                spellName = facts.spellName,
                                class = className,
                                classLevel = facts.level > 0 and facts.level or playerLevel,
                                levelScore = facts.level > 0 and facts.level or playerLevel,
                                rank = rank,
                                durationSec = facts.durationSec,
                                targetMode = facts.targetMode,
                            }
                        end
                    end
                end
            end
        end
    end
end

local function publishCatalog(classes, playerLevel, bookScanCompleted)
    local candidates = {}
    addSpellCandidates(candidates, state.bookNames, classes, playerLevel)
    addAACandidates(candidates, classes, playerLevel)
    table.sort(candidates, function(a, b)
        if a.classLevel ~= b.classLevel then return a.classLevel > b.classLevel end
        if a.durationSec ~= b.durationSec then return a.durationSec > b.durationSec end
        if a.type ~= b.type then return a.type == 'aa' end
        if a.rank ~= b.rank then return (a.rank or 0) > (b.rank or 0) end
        return a.name:lower() < b.name:lower()
    end)

    state.catalog = candidates
    state.spellCount = 0
    state.aaCount = 0
    for _, candidate in ipairs(candidates) do
        if candidate.type == 'spell' then state.spellCount = state.spellCount + 1
        else state.aaCount = state.aaCount + 1 end
    end
    state.scanning = false
    state.complete = true
    if bookScanCompleted then
        state.bookCacheCheckedAt = os.time()
        state.bookCacheValid = true
        if saveBookCache() then
            state.status = 'Scribed spell list refreshed; it will be checked again in 15 minutes.'
        end
    end
    local age = math.max(0, os.time() - (state.bookCacheCheckedAt or 0))
    state.nextScanAt = os.clock() + math.max(1, BOOK_CACHE_REFRESH_SEC - age)
end

local function rosterSpellKey(entry)
    return nameKey(entry and (entry.spellName or entry.spell or ''))
end

local function rosterContainsSpell(spellName, roster)
    local key = nameKey(spellName)
    if key == '' then return false end
    for _, entry in ipairs(roster or cfg.roster or {}) do
        if rosterSpellKey(entry) == key then return true end
    end
    return false
end

local function defaultScope(candidate)
    return candidate.targetMode == 'self' and 'self' or 'group'
end

local function makeRosterEntry(candidate)
    return {
        type = candidate.type,
        name = candidate.name,
        spellName = candidate.spellName,
        class = candidate.class,
        targetMode = candidate.targetMode,
        scope = defaultScope(candidate),
        durationSec = candidate.durationSec,
    }
end

local function rosterLimit()
    local n = math.floor(tonumber(cfg.maxBuffs) or SUGGESTED_ROSTER_SIZE)
    return math.max(1, math.min(ROSTER_USER_MAX, ROSTER_HARD_MAX, n))
end

local function evalResult(value)
    if type(value) ~= 'boolean' and type(value) ~= 'number' and value ~= nil then
        local ok, v = pcall(value)
        value = ok and v or nil
    end
    if value == true or value == 1 then return true end
    if value == false or value == 0 then return false end
    return nil
end

local stackCache = {}

-- true / false / nil (unknown). MQ's Spell.WillStack[name] is the documented
-- member; StacksWith is kept as a fallback. Results are cached per pair.
local function stacksWith(candidateName, otherName)
    local key = candidateName .. '\31' .. otherName
    local cached = stackCache[key]
    if cached ~= nil then
        if cached == 1 then return true end
        if cached == 0 then return false end
        return nil
    end
    local result = nil
    pcall(function()
        local spell = mq.TLO.Spell(candidateName)
        if not spell or not spell() then return end
        if spell.WillStack then result = evalResult(spell.WillStack(otherName)) end
        if result == nil and spell.StacksWith then result = evalResult(spell.StacksWith(otherName)) end
    end)
    stackCache[key] = result == true and 1 or (result == false and 0 or 2)
    return result
end

local function stacksWithAll(candidateName, chosen)
    local unknown = 0
    for _, other in ipairs(chosen) do
        local stacks = stacksWith(candidateName, other)
        if stacks == false then return false, unknown end
        if stacks == nil then unknown = unknown + 1 end
    end
    return true, unknown
end

-- Does anyone this buff would reach want any of its effect categories?
-- Self-only buffs only need the caster to want them.
local function candidateWanted(candidate)
    local members = audienceMembers()
    if #members == 0 then return true end
    local cats = spellCategories(candidate.spellName)
    for index, info in ipairs(members) do
        if candidate.targetMode ~= 'self' or index == 1 then
            for key in pairs(cats) do
                if info.wants[key] then return true end
            end
        end
        if candidate.targetMode == 'self' then break end
    end
    return false
end

local COVERAGE_ORDER = { 'melee', 'defense', 'resist', 'mana', 'spellhaste' }

local function suggestRoster()
    local chosen = {}
    local proposal = {}
    local limit = rosterLimit()
    local selectedCount = #(cfg.roster or {})
    local unknownCount = 0
    local conflictCount = 0
    local duplicateCount = 0
    local unwantedCount = 0
    local tooHighCount = 0
    local playerLevel = 0
    pcall(function() playerLevel = tonumber(mq.TLO.Me.Level()) or 0 end)
    stackCache = {}

    for _, entry in ipairs(cfg.roster or {}) do
        if entry.spellName and entry.spellName ~= '' then
            chosen[#chosen + 1] = entry.spellName
        end
    end

    local function tryAdd(candidate)
        if selectedCount >= limit then return false end
        if rosterContainsSpell(candidate.spellName) or rosterContainsSpell(candidate.spellName, proposal) then return false end
        local ok, unknown = stacksWithAll(candidate.spellName, chosen)
        if not ok then
            conflictCount = conflictCount + 1
            return false
        end
        unknownCount = unknownCount + unknown
        local entry = makeRosterEntry(candidate)
        entry.selected = true
        proposal[#proposal + 1] = entry
        chosen[#chosen + 1] = candidate.spellName
        selectedCount = selectedCount + 1
        return true
    end

    -- Only buffs the caster can use right now, that someone in the group wants.
    local usable = {}
    for _, candidate in ipairs(state.catalog) do
        if rosterContainsSpell(candidate.spellName) then
            duplicateCount = duplicateCount + 1
        elseif playerLevel > 0 and (candidate.classLevel or 0) > playerLevel then
            tooHighCount = tooHighCount + 1
        elseif not candidateWanted(candidate) then
            unwantedCount = unwantedCount + 1
        else
            usable[#usable + 1] = candidate
        end
    end

    -- Pass 1: the best (highest level) buff for each effect category, so the
    -- limited slots cover the most ground. Pass 2: fill the rest by level.
    for _, cat in ipairs(COVERAGE_ORDER) do
        if selectedCount >= limit then break end
        for _, candidate in ipairs(usable) do
            if spellCategories(candidate.spellName)[cat] and not rosterContainsSpell(candidate.spellName, proposal) then
                if tryAdd(candidate) then break end
            end
        end
    end
    for _, candidate in ipairs(usable) do
        if selectedCount >= limit then break end
        tryAdd(candidate)
    end

    state.proposal = proposal
    state.stackUnknownCount = unknownCount
    state.stackConflictCount = conflictCount
    state.duplicateCount = duplicateCount
    state.discoveryRequested = false
    state.proposalOpened = false
    state.status = string.format('%d suggested buff%s ready for review (limit %d; skipped %d above your level, %d nobody here wants, %d non-stacking).',
        #proposal, #proposal == 1 and '' or 's', limit, tooHighCount, unwantedCount, conflictCount)
    dlog('SUGGEST: %d proposed, limit=%d level=%d catalog=%d tooHigh=%d unwanted=%d conflicts=%d stackUnknown=%d',
        #proposal, limit, playerLevel, #state.catalog, tooHighCount, unwantedCount, conflictCount, unknownCount)
    if #proposal > 0 then
        state.proposalOpen = true
    else
        state.proposalOpen = false
        if #(cfg.roster or {}) >= limit then
            state.status = string.format('The roster already has %d or more entries; raise the buff limit or remove one before generating more suggestions.', limit)
        elseif #state.catalog == 0 then
            state.status = 'No eligible scribed class buffs or trained class AAs were found.'
        else
            state.status = 'No additional non-duplicate, stacking-compatible suggestions were found.'
        end
    end
end

local function stepScan()
    if not mq or not mq.TLO then return end
    local classes = classNames()
    local playerLevel = 0
    pcall(function() playerLevel = tonumber(mq.TLO.Me.Level()) or 0 end)
    if playerLevel <= 0 then return end

    local signature = classSignature(classes, playerLevel)
    if state.bookCacheValid
        and os.time() - (state.bookCacheCheckedAt or 0) >= BOOK_CACHE_REFRESH_SEC then
        state.bookCacheValid = false
    end
    if state.signature ~= signature and state.bookCacheValid then
        state.signature = signature
        publishCatalog(classes, playerLevel, false)
        if state.discoveryRequested then suggestRoster() end
        return
    end
    if state.refreshRequested or (state.complete and os.clock() >= state.nextScanAt)
        or (not state.complete and not state.scanning and not state.bookCacheValid) then
        beginScan(signature)
    end
    if not state.scanning then return end

    local last = math.min(BOOK_SLOT_MAX, state.cursor + BOOK_SLOTS_PER_TICK - 1)
    for slotIndex = state.cursor, last do
        local name = readBookName(slotIndex)
        if name then state.bookNames[nameKey(name)] = cleanName(name) end
    end
    state.cursor = last + 1

    if state.cursor > BOOK_SLOT_MAX then
        if #classes == 0 then
            state.scanning = false
            state.complete = true
            state.bookCacheCheckedAt = os.time()
            state.bookCacheValid = true
            state.nextScanAt = os.clock() + BOOK_CACHE_REFRESH_SEC
            if saveBookCache() then
                state.status = 'Scribed spell list refreshed; it will be checked again in 15 minutes.'
            end
            state.discoveryRequested = false
            state.refreshRequested = false
            state.status = 'Could not discover the character class list. The buff roster was not changed.'
            return
        end
        publishCatalog(classes, playerLevel, true)
        if state.discoveryRequested then suggestRoster() end
        state.refreshRequested = false
    end
end

local function groupTargets()
    local out = {}
    local seen = {}
    local selfId = 0
    pcall(function() selfId = tonumber(mq.TLO.Me.ID()) or 0 end)
    if selfId > 0 then
        out[#out + 1] = selfId
        seen[selfId] = true
    end

    local count = 0
    pcall(function() count = tonumber(mq.TLO.Group.Members()) or 0 end)
    for index = 0, math.min(count, 5) do
        pcall(function()
            local member = mq.TLO.Group.Member(index)
            if member and member() then
                local id = tonumber(member.ID()) or 0
                if id > 0 and not seen[id] then
                    seen[id] = true
                    out[#out + 1] = id
                end
            end
        end)
    end
    return out, selfId
end

-- ---------------------------------------------------------------------------
-- Audience: which group members want which kinds of buff.
-- A spell's effect categories are read once and cached; each member's wanted
-- categories are resolved once (then every 2 min) and cached, so the per-tick
-- check is two table lookups and no extra TLO reads.
-- ---------------------------------------------------------------------------
local CATEGORIES = {
    { key = 'melee',      label = 'Melee',       tip = 'Attack, STR, DEX and melee haste' },
    { key = 'defense',    label = 'Defense',     tip = 'AC, max HP, STA, AGI and HP regen' },
    { key = 'resist',     label = 'Resists',     tip = 'Fire, cold, poison, disease and magic resist' },
    { key = 'mana',       label = 'Mana',        tip = 'INT, WIS, mana regen and max mana' },
    { key = 'spellhaste', label = 'Spell haste', tip = 'Spell casting haste' },
    { key = 'util',       label = 'Utility',     tip = 'Everything else (movement, invis, breathing, etc.)' },
}
local SPA_CATEGORY = {
    [2] = 'melee', [4] = 'melee', [5] = 'melee', [11] = 'melee', [98] = 'melee',
    [1] = 'defense', [6] = 'defense', [7] = 'defense', [69] = 'defense', [100] = 'defense',
    [46] = 'resist', [47] = 'resist', [48] = 'resist', [49] = 'resist', [50] = 'resist',
    [8] = 'mana', [9] = 'mana', [15] = 'mana', [97] = 'mana',
    [127] = 'spellhaste',
}
local PRESETS = {
    melee      = { 'melee', 'defense', 'resist', 'util' },
    hybrid     = { 'melee', 'defense', 'resist', 'mana', 'util' },
    caster     = { 'defense', 'resist', 'mana', 'spellhaste', 'util' },
    all        = { 'melee', 'defense', 'resist', 'mana', 'spellhaste', 'util' },
}
local PROFILES = {
    { key = 'auto',   label = 'Auto (recommended)' },
    { key = 'melee',  label = 'Pure melee' },
    { key = 'hybrid', label = 'Hybrid' },
    { key = 'caster', label = 'Caster / healer' },
    { key = 'all',    label = 'Everything' },
    { key = 'custom', label = 'Custom' },
}
local CLASS_KIND = {
    WAR = 'melee', ROG = 'melee', MNK = 'melee', BER = 'melee',
    PAL = 'hybrid', RNG = 'hybrid', SHD = 'hybrid', BST = 'hybrid', BRD = 'hybrid',
    CLR = 'caster', DRU = 'caster', SHM = 'caster', ENC = 'caster',
    MAG = 'caster', WIZ = 'caster', NEC = 'caster',
}
local CLASS_ALIAS = {
    warrior = 'WAR', rogue = 'ROG', monk = 'MNK', berserker = 'BER', paladin = 'PAL',
    ranger = 'RNG', shadowknight = 'SHD', beastlord = 'BST', bard = 'BRD', cleric = 'CLR',
    druid = 'DRU', shaman = 'SHM', enchanter = 'ENC', magician = 'MAG', wizard = 'WIZ',
    necromancer = 'NEC',
}

local spellCats = {}
local audience = { byId = {}, list = nil, listAt = 0 }

function resetAudience()
    audience.byId, audience.list, audience.listAt = {}, nil, 0
end

function spellCategories(spellName)
    local cats = spellCats[spellName]
    if cats then return cats end
    cats = {}
    pcall(function()
        local spell = mq.TLO.Spell(spellName)
        if not spell or not spell() then return end
        for i = 1, 12 do
            local v = spell.Attrib(i)
            if type(v) ~= 'number' and v ~= nil then v = v() end
            v = tonumber(v)
            if not v then break end
            local key = SPA_CATEGORY[v]
            if key then cats[key] = true end
        end
    end)
    if next(cats) == nil then cats.util = true end
    spellCats[spellName] = cats
    return cats
end

local function normClass(value)
    local s = tostring(value or ''):lower():gsub('[%s_]', '')
    if s == '' then return nil end
    return CLASS_ALIAS[s] or s:upper():sub(1, 3)
end

local function wantsFromList(list)
    local set = {}
    for _, key in ipairs(list) do set[key] = true end
    return set
end

local function autoWants(classes)
    local set, known = {}, false
    for _, class in ipairs(classes) do
        local kind = CLASS_KIND[normClass(class) or '']
        if kind then
            known = true
            for _, key in ipairs(PRESETS[kind]) do set[key] = true end
        end
    end
    if not known then return wantsFromList(PRESETS.all), false end
    return set, true
end

local function classesForMember(id, name, isSelf)
    if isSelf and core and type(core.myClasses) == 'table' and #core.myClasses > 0 then
        return core.myClasses
    end
    local bn = core and core.boxnet
    if bn and bn.peer then
        local ok, peer = pcall(bn.peer, name)
        local classes = ok and type(peer) == 'table' and type(peer.hb) == 'table' and peer.hb.classes or nil
        if type(classes) == 'table' and #classes > 0 then return classes end
    end
    local class = nil
    pcall(function() class = mq.TLO.Spawn('id ' .. id).Class.ShortName() end)
    return class and { tostring(class) } or {}
end

local function wantsForSetting(setting, classes)
    local profile = setting and setting.profile or 'auto'
    if profile == 'custom' then
        local set = {}
        for key in tostring(setting.cats or ''):gmatch('[%a]+') do set[key] = true end
        return set, 'custom'
    end
    if PRESETS[profile] then return wantsFromList(PRESETS[profile]), profile end
    local set, known = autoWants(classes)
    return set, known and 'auto' or 'auto (classes unknown: everything)'
end

local function memberAudience(id, selfId)
    local info = audience.byId[id]
    if info and os.clock() < info.expires then return info end
    local name = ''
    if id == selfId then
        pcall(function() name = tostring(mq.TLO.Me.CleanName() or '') end)
    else
        pcall(function() name = tostring(mq.TLO.Spawn('id ' .. id).CleanName() or '') end)
    end
    if name == '' then return nil end
    local classes = classesForMember(id, name, id == selfId)
    local wants, how = wantsForSetting(cfg.members and cfg.members[name], classes)
    info = { name = name, classes = classes, wants = wants, how = how, expires = os.clock() + 120 }
    audience.byId[id] = info
    local keys = {}
    for _, c in ipairs(CATEGORIES) do if wants[c.key] then keys[#keys + 1] = c.key end end
    dlog('AUDIENCE: %s classes=%s profile=%s wants=%s', name, table.concat(classes, '/'), how, table.concat(keys, ','))
    return info
end

local function audienceWants(candidate, id, selfId)
    local info = memberAudience(id, selfId)
    if not info then return true end
    for key in pairs(spellCategories(candidate.spellName)) do
        if info.wants[key] then return true end
    end
    return false
end

local function canStack(spellName, targetId)
    local can = nil
    local ok = pcall(function()
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.StacksSpawn then
            can = spell.StacksSpawn(targetId)
            -- MQ returns a TLO result object; it must be evaluated with ().
            if type(can) ~= 'boolean' and type(can) ~= 'number' and can ~= nil then
                can = can()
            end
        end
    end)
    if ok and (can == true or can == 1) then return true end
    if ok and (can == false or can == 0) then return false end
    -- No answer (common for group members whose buffs MQ cannot read): the
    -- missing-buff check already passed, so cast rather than silently skip.
    state.lastStackQueryError = 'StacksSpawn returned no result for ' .. spellName .. '; casting anyway.'
    return true
end

local function attemptKey(candidate, targetId)
    return tostring(targetId) .. '|' .. nameKey(candidate.spellName)
end

local function isTargetAlive(targetId, selfId)
    if targetId == selfId then return true end
    if runtime and runtime.isSpawnAlive then
        local ok, alive = pcall(runtime.isSpawnAlive, targetId)
        if ok then return alive == true end
    end
    return true
end

local function isInRange(candidate, targetId)
    if targetId == 0 then return false end
    if not runtime or not runtime.isTargetInRange then return false end
    local ok, inRange = pcall(runtime.isTargetInRange, candidate.spellName, targetId)
    return ok and inRange == true
end

local function buffIsActive(targetId, spellName)
    if not runtime or not runtime.buffActive then return nil end
    local ok, active = pcall(runtime.buffActive, targetId, spellName)
    if not ok then return nil end
    if active ~= true and active ~= false then return nil end
    return active
end

local function tempGemForSpell(spellName)
    local slot = nil
    pcall(function() slot = tonumber(mq.TLO.Me.Gem(spellName)()) end)
    if slot and slot > 0 then return slot end

    local count = 12
    if core and core.getNumGems then
        local ok, value = pcall(core.getNumGems)
        if ok then count = tonumber(value) or count end
    end
    for index = count, 1, -1 do
        local primary = nil
        if runtime and runtime.getPrimarySpellForGem then
            pcall(function() primary = runtime.getPrimarySpellForGem(index) end)
        end
        if type(primary) == 'string' and primary ~= '' then return index end
    end
    state.noSwapGem = true
    return nil
end

local function aaReady(candidate)
    local ready = false
    pcall(function()
        local aa = mq.TLO.Me.AltAbility(candidate.name)
        if aa and aa() and (tonumber(aa.Rank()) or 0) > 0 then
            ready = mq.TLO.Me.AltAbilityReady(candidate.name)() == true
        end
    end)
    return ready
end

local function candidateForRoster(entry)
    local wantedSpell = nameKey(entry.spellName)
    local wantedName = nameKey(entry.name)
    for _, candidate in ipairs(state.catalog) do
        if candidate.type == entry.type
            and nameKey(candidate.spellName) == wantedSpell
            and (wantedName == '' or nameKey(candidate.name) == wantedName) then
            return candidate
        end
    end
    -- A roster entry the user kept stays castable while the character still
    -- owns it, even if class discovery came back empty or the entry no longer
    -- matches the discovery filters.
    local owned = false
    if entry.type == 'aa' then
        pcall(function() owned = (tonumber(mq.TLO.Me.AltAbility(entry.name).Rank()) or 0) > 0 end)
    elseif bookHasSpell(state.bookNames, entry.spellName) then
        owned = true
    else
        pcall(function() owned = (tonumber(mq.TLO.Me.Book(entry.spellName)()) or 0) > 0 end)
    end
    if not owned then return nil end
    return {
        type = entry.type,
        name = entry.name,
        spellName = entry.spellName,
        class = entry.class,
        targetMode = entry.targetMode,
        durationSec = entry.durationSec,
    }
end

-- True while the target or any extended target is a named NPC; long buffs
-- never interrupt that fight.
local function namedNpcEngaged()
    local found = false
    local function check(spawn)
        if found or not spawn or not spawn() then return end
        local kind = tostring(spawn.Type() or ''):lower()
        if kind == 'npc' and spawn.Named() == true and (tonumber(spawn.PctHP()) or 0) > 0 then found = true end
    end
    pcall(function() check(mq.TLO.Target) end)
    for index = 1, 20 do
        if found then break end
        pcall(function()
            local id = tonumber(mq.TLO.Me.XTarget(index).ID()) or 0
            if id > 0 then check(mq.TLO.Spawn(id)) end
        end)
    end
    return found
end

local function nextLongBuffCast(inCombat)
    refresh()
    if not cfg.enabled then dlogChange('gate', 'GATE: casting is off') return nil end
    if not state.complete then dlogChange('gate', 'GATE: spellbook scan not complete (scanning=%s)', tostring(state.scanning)) return nil end
    if not runtime or not mq or not ctrl then dlogChange('gate', 'GATE: host not ready') return nil end
    if #(cfg.roster or {}) == 0 then dlogChange('gate', 'GATE: roster empty') return nil end
    if ctrl.downtime_buffing == false then dlogChange('gate', 'GATE: TAC Downtime Buffs is off') return nil end
    if ctrl.running ~= true then dlogChange('gate', 'GATE: ctrl.running is not true') return nil end
    if runtime.isCasting and runtime.isCasting() then dlogChange('gate', 'GATE: already casting') return nil end
    if inCombat == true and namedNpcEngaged() then dlogChange('gate', 'GATE: named NPC engaged, no buffing') return nil end
    if brk.medding then dlogChange('gate', 'GATE: resting during rebuff break') return nil end
    dlogChange('gate', 'GATE: open (inCombat=%s)', tostring(inCombat == true))

    local targets, selfId = groupTargets()
    if #targets == 0 then return nil end
    local now = os.clock()
    if now < state.nextQueryAt then return nil end

    local firstCandidate = math.max(1, math.min(state.candidateCursor or 1, #cfg.roster + 1))
    for candidateIndex = firstCandidate, #cfg.roster do
        local rosterEntry = cfg.roster[candidateIndex]
        local candidate = rosterEntry and candidateForRoster(rosterEntry)
        if candidate and (candidate.type ~= 'aa' or aaReady(candidate)) then
            local gem = nil
            if candidate.type == 'spell' then
                if inCombat == true then
                    pcall(function() gem = tonumber(mq.TLO.Me.Gem(candidate.spellName)()) end)
                    if gem and gem <= 0 then gem = nil end
                    if not gem then
                        state.diag = candidate.spellName .. ' is not memorized; it will be swapped in when the fight ends.'
                    end
                else
                    gem = tempGemForSpell(candidate.spellName)
                    if not gem then state.noSwapGem = true end
                end
            end

            if candidate.type == 'aa' or gem then
                local scope = rosterEntry.scope or defaultScope(candidate)
                if candidate.targetMode == 'self' then scope = 'self' end
                local targetStart = candidateIndex == firstCandidate and (state.targetCursor or 1) or 1
                local targetEnd = scope == 'self' and 1 or #targets
                local targetList = scope == 'self' and { selfId } or targets

                if candidate.targetMode == 'group' then
                    local missingTargetId = nil
                    for _, targetId in ipairs(targets) do
                        if isTargetAlive(targetId, selfId) and audienceWants(candidate, targetId, selfId) and isInRange(candidate, targetId) then
                            local active = buffIsActive(targetId, candidate.spellName)
                            if active == false then
                                missingTargetId = targetId
                                break
                            end
                        end
                    end
                    local key = missingTargetId and attemptKey(candidate, missingTargetId) or nil
                    local lastAttempt = key and attempted[key] or nil
                    if missingTargetId
                        and (not lastAttempt or (now - lastAttempt) >= RETRY_SEC)
                        and canStack(candidate.spellName, missingTargetId) then
                        attempted[key] = now
                        attemptCounts[key] = (attemptCounts[key] or 0) + 1
                        state.candidateCursor = candidateIndex + 1
                        state.targetCursor = 1
                        dlog('CAST REQUEST (group): %s on id %d, gem=%s, attempt %d', candidate.spellName, missingTargetId, tostring(gem), attemptCounts[key] or 0)
                        return {
                            autoBuffType = candidate.type,
                            name = candidate.name,
                            spell = candidate.spellName,
                            cls = candidate.class,
                            kind = candidate.type == 'aa' and 'aa' or 'gem',
                            target = missingTargetId == selfId and 'F: Whole Group' or 'F: Me, then Group',
                            when = 'missing buff',
                            pct = 100,
                            gem = gem,
                        }, missingTargetId
                    end
                else
                    for targetIndex = targetStart, targetEnd do
                        local targetId = targetList[targetIndex]
                        local key = attemptKey(candidate, targetId)
                        local lastAttempt = attempted[key]
                        local active = nil
                        local wanted = audienceWants(candidate, targetId, selfId)
                        if wanted then active = buffIsActive(targetId, candidate.spellName) end
                        if isTargetAlive(targetId, selfId)
                            and active == false
                            and (not lastAttempt or (now - lastAttempt) >= RETRY_SEC)
                            and isInRange(candidate, targetId)
                            and canStack(candidate.spellName, targetId) then
                            attempted[key] = now
                            attemptCounts[key] = (attemptCounts[key] or 0) + 1
                            state.candidateCursor = candidateIndex
                            state.targetCursor = targetIndex < targetEnd and targetIndex + 1 or 1
                            dlog('CAST REQUEST (single): %s on id %d, gem=%s, attempt %d', candidate.spellName, targetId, tostring(gem), attemptCounts[key] or 0)
                            return {
                                autoBuffType = candidate.type,
                                name = candidate.name,
                                spell = candidate.spellName,
                                cls = candidate.class,
                                kind = candidate.type == 'aa' and 'aa' or 'gem',
                                target = targetId == selfId and 'F: Myself' or 'F: Me, then Group',
                                when = 'missing buff',
                                pct = 100,
                                gem = gem,
                            }, targetId
                        end
                    end
                end
            end
        end
        state.candidateCursor = candidateIndex + 1
        state.targetCursor = 1
    end

    state.candidateCursor = 1
    state.targetCursor = 1
    state.nextQueryAt = now + 2
    if inCombat ~= true then state.diag = nil end
    for key, at in pairs(attempted) do
        if now - at > 300 then attempted[key] = nil end
    end
    return nil
end

-- First roster buff that is missing on anyone alive in the group (range is
-- ignored here; the break walks to them). Returns candidate, targetId,
-- inRange, attemptKey.
local function firstMissing()
    local targets, selfId = groupTargets()
    for _, rosterEntry in ipairs(cfg.roster or {}) do
        local candidate = candidateForRoster(rosterEntry)
        if candidate and (candidate.type ~= 'aa' or aaReady(candidate)) then
            local scope = rosterEntry.scope or defaultScope(candidate)
            if candidate.targetMode == 'self' then scope = 'self' end
            local list = scope == 'self' and { selfId } or targets
            for _, id in ipairs(list) do
                local key = attemptKey(candidate, id)
                if id > 0 and isTargetAlive(id, selfId)
                    and audienceWants(candidate, id, selfId)
                    and (attemptCounts[key] or 0) < BREAK_MAX_ATTEMPTS
                    and buffIsActive(id, candidate.spellName) == false
                    and canStack(candidate.spellName, id) then
                    return candidate, id, id == selfId or isInRange(candidate, id), key
                end
            end
        end
    end
    return nil
end

local function endBreak()
    if brk.active and mq then
        local sitting = false
        pcall(function() sitting = mq.TLO.Me.Sitting() == true end)
        if sitting then mq.cmd('/stand') end
    end
    -- Resume only the boxes this break paused.
    local bn = core and core.boxnet
    if bn and bn.command then
        for _, name in ipairs(brk.paused) do
            local ok, sent = pcall(bn.command, name, 'run')
            dlog('GATHER: resumed %s (sent=%s)', name, tostring(ok and sent))
        end
    end
    brk.paused, brk.gatherAt = {}, 0
    brk.active, brk.medding, brk.finishUntil = false, false, nil
    attemptCounts = {}
end

-- Box Network: pauses every running box in the group and sends it to this
-- character with MQ2Nav, so out-of-range members come into spell range.
-- Re-sent every 10 s. Returns the number of boxes being gathered (0 means
-- Box Network cannot help and the caller should walk instead).
local function gatherGroup()
    local bn = core and core.boxnet
    if not (cfg.gatherGroup and bn and bn.command and bn.peers) then return 0 end
    local okAvail, avail = pcall(bn.available)
    if okAvail and avail == false then return 0 end
    local myName, myId = '', 0
    pcall(function() myName = tostring(mq.TLO.Me.CleanName() or '') end)
    pcall(function() myId = tonumber(mq.TLO.Me.ID()) or 0 end)
    if myName == '' or myId <= 0 then return 0 end
    local okPeers, peers = pcall(bn.peers)
    if not okPeers or type(peers) ~= 'table' then return 0 end

    local count = 0
    local resend = os.clock() - brk.gatherAt >= 10
    for _, peer in ipairs(peers) do
        local isMember = false
        if bn.isGroupMember then
            local okMember, member = pcall(bn.isGroupMember, peer.name)
            isMember = okMember and member == true
        end
        if isMember and peer.name ~= myName then
            count = count + 1
            if resend then
                local known = false
                for _, n in ipairs(brk.paused) do if n == peer.name then known = true end end
                if not known and peer.hb and peer.hb.running == true then
                    brk.paused[#brk.paused + 1] = peer.name
                    pcall(bn.command, peer.name, 'pause')
                end
                local ok, sent, why = pcall(bn.command, peer.name, '/nav id ' .. myId .. ' distance=12')
                dlog('GATHER: %s -> come to %s (id %d): sent=%s %s', peer.name, myName, myId, tostring(ok and sent), tostring(why or ''))
            end
        end
    end
    if resend then brk.gatherAt = os.clock() end
    return count
end

-- Walks to a group member until the spell can reach them. Blocking, with
-- aborts on any threat; returns true when in range.
local function walkToMember(candidate, id)
    local meshOk = false
    pcall(function() meshOk = mq.TLO.Navigation.MeshLoaded() == true end)
    if not meshOk then return false end
    mq.cmdf('/nav id %d distance=15', id)
    dlog('NAV: walking to id %d for %s', id, candidate.spellName)
    local deadline = os.clock() + BREAK_NAV_TIMEOUT_SEC
    while os.clock() < deadline do
        mq.delay(250)
        if runtime.hasDowntimeAggroThreat and runtime.hasDowntimeAggroThreat() then break end
        if isInRange(candidate, id) then break end
        local navActive = true
        pcall(function() navActive = mq.TLO.Navigation.Active() == true end)
        if not navActive then break end
    end
    mq.cmd('/nav stop')
    dlog('NAV: stopped, inRange=%s', tostring(isInRange(candidate, id)))
    return isInRange(candidate, id)
end

-- Full diagnostic dump of why each roster entry is or is not being cast.
-- Written to the debug log every 10 seconds while debug is on.
local function snapshot()
    if not cfg.debug or not mq then return end
    local mode, sub = '?', '?'
    if ctrl then mode, sub = tostring(ctrl.mode), tostring(ctrl.submode) end
    local function tlo(fn) local v; pcall(function() v = fn() end); return tostring(v) end
    dlog('---- SNAPSHOT v%s ----', plugin.version)
    dlog('TAC: mode=%s/%s running=%s downtime_buffing=%s medBreakActive=%s forceBreak=%s',
        mode, sub, tostring(ctrl and ctrl.running), tostring(ctrl and ctrl.downtime_buffing),
        tostring(runtime and runtime.medBreakActive), tostring(cfg.forceBreak))
    dlog('Me: level=%s mana=%s%% combat=%s sitting=%s moving=%s casting=%s target=%s',
        tlo(function() return mq.TLO.Me.Level() end), tlo(function() return mq.TLO.Me.PctMana() end),
        tlo(function() return mq.TLO.Me.Combat() end), tlo(function() return mq.TLO.Me.Sitting() end),
        tlo(function() return mq.TLO.Me.Moving() end), tlo(function() return mq.TLO.Me.Casting.ID() end),
        tlo(function() return mq.TLO.Target.CleanName() end))
    dlog('Plugin: enabled=%s scanComplete=%s scanning=%s catalog=%d bookSpells=%d classes=[%s] namedEngaged=%s break(active=%s medding=%s cooldown=%.0fs)',
        tostring(cfg.enabled), tostring(state.complete), tostring(state.scanning), #state.catalog,
        (function() local n = 0 for _ in pairs(state.bookNames) do n = n + 1 end return n end)(),
        table.concat(classNames(), ','), tostring(namedNpcEngaged()),
        tostring(brk.active), tostring(brk.medding), math.max(0, brk.cooldownUntil - os.clock()))
    dlog('Hooks: runtime.nextLongBuffCast=%s  status="%s"', tostring(runtime and runtime.nextLongBuffCast == nextLongBuffCast), tostring(state.status))
    local targets, selfId = groupTargets()
    dlog('Group: %d member id(s) incl. self (self=%d)', #targets, selfId)
    for index, entry in ipairs(cfg.roster or {}) do
        local candidate = candidateForRoster(entry)
        local gem = tlo(function() return mq.TLO.Me.Gem(entry.spellName)() end)
        dlog('[%d] %s (%s, %s/%s): inCatalog=%s memorizedGem=%s inBook=%s aaReady=%s',
            index, entry.spellName, entry.type, tostring(entry.targetMode), tostring(entry.scope),
            tostring(candidate ~= nil), gem, tostring(bookHasSpell(state.bookNames, entry.spellName)),
            entry.type == 'aa' and tostring(candidate and aaReady(candidate)) or 'n/a')
        if candidate then
            for _, id in ipairs(targets) do
                local name = tlo(function() return mq.TLO.Spawn(id).CleanName() end)
                local stacks = tlo(function()
                    local value = mq.TLO.Spell(candidate.spellName).StacksSpawn(id)
                    if type(value) ~= 'boolean' and type(value) ~= 'number' and value ~= nil then value = value() end
                    return value
                end)
                dlog('     -> %s #%d: alive=%s inRange=%s distance=%s hasBuff=%s stacks=%s tries=%d',
                    name, id, tostring(isTargetAlive(id, selfId)), tostring(id == selfId or isInRange(candidate, id)),
                    tlo(function() return mq.TLO.Spawn(id).Distance3D() end),
                    tostring(buffIsActive(id, candidate.spellName)), stacks,
                    attemptCounts[attemptKey(candidate, id)] or 0)
            end
        end
    end
    dlog('---- END SNAPSHOT ----')
end

-- Called by TAC between pulls. While any roster buff is missing on a living
-- group member this returns true, so the puller/hunter holds off new pulls.
-- The break rests to recover mana, walks to members who are out of range,
-- lets TAC's downtime path cast and restore gems, and gives up after
-- BREAK_MAX_SEC (then waits BREAK_COOLDOWN_SEC before trying again).
function plugin.onBetweenPulls()
    refresh()
    if not cfg.forceBreak or not cfg.enabled or not state.complete or not runtime or not mq or not ctrl
        or ctrl.downtime_buffing == false or #(cfg.roster or {}) == 0 then
        dlogChange('break', 'BREAK: not eligible (forceBreak=%s enabled=%s scanComplete=%s downtime=%s roster=%d)',
            tostring(cfg.forceBreak), tostring(cfg.enabled), tostring(state.complete),
            tostring(ctrl and ctrl.downtime_buffing), #(cfg.roster or {}))
        if brk.active then endBreak() end
        return false
    end
    local now = os.clock()
    if now < brk.cooldownUntil then dlogChange('break', 'BREAK: cooling down after a timeout') return false end
    if namedNpcEngaged() or (runtime.hasDowntimeAggroThreat and runtime.hasDowntimeAggroThreat()) then
        dlogChange('break', 'BREAK: aborted/skipped, aggro threat or named NPC')
        if brk.active then endBreak() end
        return false
    end
    if runtime.isCasting and runtime.isCasting() then return brk.active end

    local candidate, targetId, inRange = firstMissing()
    if not candidate then
        dlogChange('break', 'BREAK: nothing missing%s', brk.active and ' (finishing)' or '')
        if not brk.active then return false end
        -- Everything is up; let TAC finish restoring any swapped gem.
        brk.finishUntil = brk.finishUntil or (now + 12)
        if not brk.medding and runtime.processDowntimeBuffing then runtime.processDowntimeBuffing() end
        if (runtime.pendingDowntimeReady or runtime.isSwitchingSpells) and now < brk.finishUntil then return true end
        endBreak()
        print('\ag[Long Buffs]\ax Rebuff break finished -- resuming pulls.')
        return false
    end
    brk.finishUntil = nil
    dlogChange('break', 'BREAK: %s missing on id %d (inRange=%s medding=%s)', candidate.spellName, targetId, tostring(inRange), tostring(brk.medding))
    if not brk.active then
        brk.active, brk.since = true, now
        state.breakText = 'Rebuff break: pulls are paused until ' .. candidate.spellName .. ' is up on the group.'
        print('\ay[Long Buffs]\ax ' .. candidate.spellName .. ' is missing -- pausing pulls for a rebuff break.')
    end
    if now - brk.since > BREAK_MAX_SEC then
        print('\ar[Long Buffs]\ax Rebuff break timed out; resuming pulls and retrying in 10 minutes.')
        endBreak()
        brk.cooldownUntil = now + BREAK_COOLDOWN_SEC
        return false
    end

    local pct = 100
    pcall(function() pct = tonumber(mq.TLO.Me.PctMana()) or 100 end)
    local gathering = 0
    if not inRange then gathering = gatherGroup() end
    if brk.medding and pct >= BREAK_MED_STOP_PCT then
        brk.medding = false
        mq.cmd('/stand')
    elseif not brk.medding and candidate.type == 'spell' and pct < BREAK_MED_START_PCT then
        brk.medding = true
    end
    if brk.medding then
        state.breakText = string.format('Rebuff break: resting to %d%% mana before casting.', BREAK_MED_STOP_PCT)
        local sitting = false
        pcall(function() sitting = mq.TLO.Me.Sitting() == true end)
        if not sitting then mq.cmd('/sit') end
        return true
    end

    if not inRange then
        if gathering > 0 then
            state.breakText = string.format('Rebuff break: waiting for %d box(es) to come into range.', gathering)
            return true
        end
        state.breakText = 'Rebuff break: moving to a group member who is out of range.'
        if not walkToMember(candidate, targetId) then
            attemptCounts[attemptKey(candidate, targetId)] = BREAK_MAX_ATTEMPTS
        end
        return true
    end

    -- In range: the downtime path memorizes, casts and restores the gem.
    state.breakText = 'Rebuff break: casting ' .. candidate.spellName .. '.'
    if runtime.processDowntimeBuffing then runtime.processDowntimeBuffing() end
    return true
end

function plugin.onCombatTick()
    refresh()
    if cfg.debug then
        if os.clock() >= dbg.nextSnapshotAt then
            dbg.nextSnapshotAt = os.clock() + 10
            local ok, err = pcall(snapshot)
            if not ok then dlog('SNAPSHOT ERROR: %s', tostring(err)) end
        end
        flushDebugLog(false)
    end
    if not cfg.enabled or not runtime or core and core.standalone then return end
    local now = os.clock()
    if now < (state.nextCombatCastAt or 0) then return end
    state.nextCombatCastAt = now + 1
    if runtime.isCasting and runtime.isCasting() then return end
    local entry, targetId = nextLongBuffCast(true)
    if not entry or not targetId or targetId <= 0 then return end
    dlog('COMBAT CAST: %s (%s) on id %d', tostring(entry.spell), tostring(entry.autoBuffType), targetId)
    if entry.autoBuffType == 'aa' then
        if runtime.fireAA and runtime.isTargetInRange(entry.spell, targetId) then
            runtime.fireAA(entry.name, entry, targetId)
        end
    elseif entry.gem and runtime.castGem then
        local ready = false
        pcall(function() ready = mq.TLO.Me.SpellReady(entry.gem)() == true end)
        if ready then runtime.castGem(entry.gem, entry, targetId) end
    end
end

function plugin.onDrawUI()
    if not state.windowOpen or not ImGui or not core then return end
    if core.pushTheme then core.pushTheme() end
    local open, visible = ImGui.Begin('Long-Duration Buffs##TACLongBuffsWindow', true)
    if not open then state.windowOpen = false end
    if visible then plugin.onDrawSettings() end
    ImGui.End()
    if core.popTheme then core.popTheme() end
end

plugin.window = {
    label = 'Buffs',
    tooltip = 'Opens the Long-Duration Buffs window: on/off, roster editor and status.',
    desc = 'Long-duration buff roster and rebuff status',
    headerButton = true,
    order = 30,
    isOpen = function() return state.windowOpen == true end,
    setOpen = function(value) state.windowOpen = value == true end,
}

function plugin.onTick()
    refresh()
    pollSharedSettings()
    stepScan()
    -- Puller/Hunter modes drive the rebuff break through onBetweenPulls.
    -- Other modes (Assist, Manual...) have no pull gap, so drive it here;
    -- plugin ticks only run out of combat.
    if ctrl and not (core and core.standalone) and ctrl.mode ~= 'Puller' and ctrl.mode ~= 'Hunter' then
        local ok, err = pcall(plugin.onBetweenPulls)
        if not ok then dlog('BREAK ERROR: %s', tostring(err)) end
    end
    if cfg.debug then
        if os.clock() >= dbg.nextSnapshotAt then
            dbg.nextSnapshotAt = os.clock() + 10
            local ok, err = pcall(snapshot)
            if not ok then dlog('SNAPSHOT ERROR: %s', tostring(err)) end
        end
        flushDebugLog(false)
    end
end

function plugin.onInit(coreApi)
    core = coreApi
    refresh()
    if runtime then runtime.nextLongBuffCast = nextLongBuffCast end
    local pluginConfig = ctrl and ctrl.plugins and ctrl.plugins[plugin.id]
    local saved = pluginConfig and pluginConfig.settings
    plugin.onLoadSettings(type(saved) == 'table' and saved or {})
    if mq and mq.event then
        scribeEventName = core and core.standalone and 'TriuneLongBuffStandaloneScribed' or 'TriuneLongBuffScribed'
        if mq.unevent then pcall(mq.unevent, scribeEventName) end
        pcall(mq.event, scribeEventName, '#*#You have finished scribing #1#.', function()
            plugin.requestRefresh()
        end)
    end
end

function plugin.onDestroy()
    dlog('==== plugin unloaded ====')
    flushDebugLog(true)
    if mq and mq.unevent and scribeEventName then
        pcall(mq.unevent, scribeEventName)
    end
    scribeEventName = nil
    if runtime and runtime.nextLongBuffCast == nextLongBuffCast then
        runtime.nextLongBuffCast = nil
    end
end

function plugin.onLoadSettings(settings)
    settings = type(settings) == 'table' and settings or {}
    if settings.enabled ~= nil then cfg.enabled = settings.enabled == true end
    if settings.forceBreak ~= nil then cfg.forceBreak = settings.forceBreak == true end
    if settings.gatherGroup ~= nil then cfg.gatherGroup = settings.gatherGroup == true end
    if settings.autoSuggest ~= nil then cfg.autoSuggest = settings.autoSuggest == true end
    if tonumber(settings.maxBuffs) then
        cfg.maxBuffs = math.max(1, math.min(ROSTER_USER_MAX, math.floor(tonumber(settings.maxBuffs))))
    end
    if settings.debug ~= nil then cfg.debug = settings.debug == true end
    local shared = sharedStore.load(mq, settings)
    local minutes = tonumber(shared.minDurationMinutes)
    if minutes then cfg.minDurationMinutes = math.max(5, math.min(180, math.floor(minutes))) end
    cfg.roster = normalizedRoster(shared.roster)
    cfg.members = normalizedMembers(shared.members)
    if tonumber(shared.maxBuffs) then
        cfg.maxBuffs = math.max(1, math.min(ROSTER_USER_MAX, math.floor(tonumber(shared.maxBuffs))))
    end
    if shared.autoSuggest ~= nil then cfg.autoSuggest = shared.autoSuggest == true end
    resetAudience()
    -- A character with no roster gets a recommended one to review.
    if cfg.autoSuggest and #(cfg.roster or {}) == 0 then state.discoveryRequested = true end
    state.sharedSignature = sharedStore.signature(sharedSettings())
    state.nextSharedPollAt = os.clock() + 2
    state.scanning = false
    state.complete = false
    state.signature = nil
    state.bookCacheValid = false
    if not loadBookCache() then
        state.status = 'Scribed-spell cache is missing or older than 15 minutes; refreshing it now.'
    end
end

function plugin.onSaveSettings()
    persistSharedSettings()
    local roster = {}
    for i, entry in ipairs(cfg.roster or {}) do
        roster[i] = {
            type = entry.type,
            name = entry.name,
            spellName = entry.spellName,
            class = entry.class,
            targetMode = entry.targetMode,
            scope = entry.scope,
            durationSec = entry.durationSec,
        }
    end

    return {
        enabled = cfg.enabled == true,
        forceBreak = cfg.forceBreak == true,
        gatherGroup = cfg.gatherGroup == true,
        autoSuggest = cfg.autoSuggest == true,
        maxBuffs = rosterLimit(),
        debug = cfg.debug == true,
        minDurationMinutes = cfg.minDurationMinutes,
        roster = roster,
    }
end

function plugin.requestRefresh()
    state.discoveryRequested = false
    state.refreshRequested = true
    state.status = 'Reloading the scribed spell list and trained AAs...'
    beginScan(nil)
end

function plugin.getRoster()
    return cfg.roster
end

function plugin.getState()
    return state
end

function plugin.getMinimumDuration()
    return cfg.minDurationMinutes
end

function plugin.setMinimumDuration(minutes)
    cfg.minDurationMinutes = math.max(5, math.min(180, math.floor(tonumber(minutes) or 15)))
    state.signature = nil
    state.complete = false
    state.scanning = false
    persistSharedSettings()
end

function plugin.rosterContainsSpell(spellName)
    return rosterContainsSpell(spellName)
end

function plugin.addRosterCandidate(candidate)
    if type(candidate) ~= 'table' or rosterContainsSpell(candidate.spellName) then return false end
    cfg.roster[#cfg.roster + 1] = makeRosterEntry(candidate)
    state.candidateCursor, state.targetCursor = 1, 1
    persistSharedSettings()
    if core and core.saveLoadout and not (core and core.standalone) then core.saveLoadout(true) end
    return true
end

function plugin.removeRosterEntry(index)
    if not cfg.roster[index] then return false end
    table.remove(cfg.roster, index)
    state.candidateCursor, state.targetCursor = 1, 1
    persistSharedSettings()
    if core and core.saveLoadout and not (core and core.standalone) then core.saveLoadout(true) end
    return true
end

function plugin.setRosterScope(index, scope)
    local entry = cfg.roster[index]
    if not entry or entry.targetMode ~= 'single' then return false end
    entry.scope = scope == 'self' and 'self' or 'group'
    persistSharedSettings()
    if core and core.saveLoadout and not (core and core.standalone) then core.saveLoadout(true) end
    return true
end

function plugin.saveSharedSettings()
    persistSharedSettings()
end

local function setEnabled(value)
    cfg.enabled = value == true
    if cfg.enabled then
        if not state.complete and not state.scanning then beginScan(nil) end
    else
        attempted = {}
        endBreak()
    end
    if core and core.saveLoadout then core.saveLoadout(true) end
end

-- Used by the standalone host: turns casting on at startup without
-- discarding a fresh scribed-spell cache.
function plugin.setCastingEnabled(value)
    setEnabled(value)
end

local function castingStatus()
    if not cfg.enabled then return 'Casting is OFF. Tick "Automatically cast long buffs" to start rebuffing.', false end
    if #(cfg.roster or {}) == 0 then return 'The roster is empty, so there is nothing to keep up.', false end
    if not state.complete then return 'Reading the spellbook before casting starts...', true end
    if namedNpcEngaged() then return 'Paused: a named NPC is engaged. Buffs resume when that fight ends.', true end
    if state.diag then return state.diag, true end
    if brk.active and state.breakText then return state.breakText, true end
    return 'Active: watching ' .. #cfg.roster .. ' roster buff(s) on you and your group.', true
end

local function closeProposal()
    state.proposalOpen = false
    state.proposalOpened = false
    state.proposal = nil
end

local function acceptProposal()
    local added = 0
    for _, entry in ipairs(state.proposal or {}) do
        if entry.selected and #cfg.roster < rosterLimit() and not rosterContainsSpell(entry.spellName) then
            cfg.roster[#cfg.roster + 1] = {
                type = entry.type,
                name = entry.name,
                spellName = entry.spellName,
                class = entry.class,
                targetMode = entry.targetMode,
                scope = entry.scope,
                durationSec = entry.durationSec,
            }
            added = added + 1
        end
    end
    state.candidateCursor = 1
    state.targetCursor = 1
    if added > 0 and not cfg.enabled then setEnabled(true) end
    state.status = string.format('Added %d suggested buff%s. Automatic casting is %s.',
        added, added == 1 and '' or 's', cfg.enabled and 'ON' or 'off')
    if core and core.saveLoadout then core.saveLoadout(true) end
    closeProposal()
end

local function drawProposal()
    if not state.proposalOpen then return end
    local popupId = 'Review suggested long-buff roster##longBuffProposal'
    if not state.proposalOpened then
        ImGui.OpenPopup(popupId)
        state.proposalOpened = true
    end
    local openModal, showModal = ImGui.BeginPopupModal(popupId, true,
        ImGuiWindowFlags and ImGuiWindowFlags.AlwaysAutoResize or 0)
    if showModal then
        if core.accent and core.colors then core.accent(core.colors.GOLD, 'Review suggested roster') end
        ImGui.TextWrapped(string.format('Review the proposed buffs. Nothing changes until you confirm. Suggestions are limited to %d buffs, skip spells above your level, spells nobody in the group wants, and spells that do not stack; you can still add more manually.', rosterLimit()))
        if state.stackConflictCount > 0 or state.duplicateCount > 0 then
            ImGui.TextWrapped(string.format('%d non-stacking candidate%s and %d duplicate spell%s were skipped.',
                state.stackConflictCount, state.stackConflictCount == 1 and '' or 's',
                state.duplicateCount, state.duplicateCount == 1 and '' or 's'))
        end
        if state.stackUnknownCount > 0 then
            ImGui.TextWrapped(string.format('%d spell-to-spell stacking comparisons were unavailable. Those suggestions are included for review; TAC will still check stacking live before casting.', state.stackUnknownCount))
        end
        local flags = ImGuiTableFlags and ImGuiTableFlags.RowBg or 0
        if ImGui.BeginTable('longBuffProposalTable', 5, flags) then
            ImGui.TableSetupColumn('Include')
            ImGui.TableSetupColumn('Buff')
            ImGui.TableSetupColumn('Class / source')
            ImGui.TableSetupColumn('Duration')
            ImGui.TableSetupColumn('Target')
            ImGui.TableHeadersRow()
            for index, entry in ipairs(state.proposal or {}) do
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local selected = ImGui.Checkbox('##longBuffProposalSelect' .. index, entry.selected == true)
                if selected ~= (entry.selected == true) then entry.selected = selected end
                ImGui.TableNextColumn()
                ImGui.TextWrapped(entry.spellName)
                ImGui.TableNextColumn()
                ImGui.Text(string.format('%s (%s)', entry.type == 'aa' and 'AA' or 'Spell', entry.class or '?'))
                ImGui.TableNextColumn()
                ImGui.Text(string.format('%d min', math.floor(((entry.durationSec or 0) + 59) / 60)))
                ImGui.TableNextColumn()
                local targetLabel = entry.targetMode == 'self' and 'Self'
                    or (entry.targetMode == 'group' and 'Group spell' or 'Self + Group')
                ImGui.Text(targetLabel)
            end
            ImGui.EndTable()
        end
        ImGui.Spacing()
        if ImGui.Button('Add selected buffs##longBuffProposalAccept', core.px(160), core.px(24)) then
            acceptProposal()
            ImGui.CloseCurrentPopup()
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel##longBuffProposalCancel', core.px(100), core.px(24)) then
            closeProposal()
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    elseif not openModal then
        closeProposal()
    end
end

function audienceMembers()
    local now = os.clock()
    if audience.list and now - audience.listAt < 3 then return audience.list end
    local list = {}
    local ids, selfId = groupTargets()
    for _, id in ipairs(ids) do
        local info = memberAudience(id, selfId)
        if info then list[#list + 1] = info end
    end
    audience.list, audience.listAt = list, now
    return list
end

local function setMemberProfile(name, profile, cats)
    cfg.members = cfg.members or {}
    if profile == 'auto' then
        cfg.members[name] = nil
    else
        cfg.members[name] = { profile = profile, cats = cats or '' }
    end
    resetAudience()
    persistSharedSettings()
end

local function drawAudience()
    if not ImGui.CollapsingHeader('Who gets which buffs##longBuffAudience') then return end
    ImGui.TextWrapped('Auto (recommended) reads each character\'s classes: pure melee skip INT/WIS, mana regen and spell haste; casters skip melee buffs. Change a profile or tick boxes to customize.')
    local members = audienceMembers()
    if #members == 0 then
        ImGui.TextDisabled('No group members found yet.')
        return
    end
    for _, info in ipairs(members) do
        local setting = cfg.members and cfg.members[info.name]
        local profile = setting and setting.profile or 'auto'
        local profileLabel = profile
        for _, p in ipairs(PROFILES) do if p.key == profile then profileLabel = p.label end end
        ImGui.Text(info.name)
        ImGui.SameLine()
        ImGui.TextDisabled('(' .. (#info.classes > 0 and table.concat(info.classes, '/') or 'classes unknown') .. ')')
        ImGui.SetNextItemWidth(170)
        if ImGui.BeginCombo('##longBuffProfile' .. info.name, profileLabel) then
            for _, p in ipairs(PROFILES) do
                local _, pressed = ImGui.Selectable(p.label, p.key == profile)
                if pressed and p.key ~= profile then
                    local cats = {}
                    for _, c in ipairs(CATEGORIES) do if info.wants[c.key] then cats[#cats + 1] = c.key end end
                    setMemberProfile(info.name, p.key, table.concat(cats, ','))
                end
            end
            ImGui.EndCombo()
        end
        for _, c in ipairs(CATEGORIES) do
            ImGui.SameLine()
            local value = ImGui.Checkbox(c.label .. '##aud' .. info.name .. c.key, info.wants[c.key] == true)
            if core and core.setTooltip and ImGui.IsItemHovered() then core.setTooltip('%s', c.tip) end
            if value ~= (info.wants[c.key] == true) then
                local cats = {}
                for _, other in ipairs(CATEGORIES) do
                    local on = other.key == c.key and value or (other.key ~= c.key and info.wants[other.key] == true)
                    if on then cats[#cats + 1] = other.key end
                end
                setMemberProfile(info.name, 'custom', table.concat(cats, ','))
            end
        end
    end
    ImGui.Spacing()
end

function plugin.onDrawSettings()
    refresh()
    if not core or not ImGui or not ctrl then return end
    local standalone = core.standalone == true
    if core.accent and core.colors then core.accent(core.colors.GOLD, 'Long-Duration Buffs') end
    ImGui.TextDisabled('Build an editable roster from eligible scribed class buffs and trained class AAs across your three classes.')

    local enabled = ImGui.Checkbox('Automatically cast long buffs##longBuffEnabled', cfg.enabled == true)
    if enabled ~= (cfg.enabled == true) then setEnabled(enabled) end
    if not standalone then
        local force = ImGui.Checkbox('Pause pulls for a rebuff/med break when a buff is missing##longBuffForce', cfg.forceBreak == true)
        if force ~= (cfg.forceBreak == true) then
            cfg.forceBreak = force
            if not force and brk.active then endBreak() end
            core.saveLoadout(true)
        end
        local gather = ImGui.Checkbox('Use Box Hub to pause and gather the group during a break##longBuffGather', cfg.gatherGroup == true)
        if gather ~= (cfg.gatherGroup == true) then
            cfg.gatherGroup = gather
            core.saveLoadout(true)
        end
    end
    local statusText, statusGood = castingStatus()
    local dbgOn = ImGui.Checkbox('Verbose debug log##longBuffDebug', cfg.debug == true)
    if dbgOn ~= (cfg.debug == true) then
        cfg.debug = dbgOn
        dbg.nextSnapshotAt = 0
        if dbgOn then
            dlog('==== debug logging started (v%s) ====', plugin.version)
        else
            flushDebugLog(true)
        end
        core.saveLoadout(true)
    end
    if cfg.debug then
        ImGui.SameLine()
        ImGui.TextDisabled(debugLogPath())
    end
    if core.colors and core.accent then
        local color = statusGood and { 0.4, 0.9, 0.4, 1.0 } or { 1.0, 0.6, 0.3, 1.0 }
        ImGui.TextColored(color[1], color[2], color[3], color[4], statusText)
    else
        ImGui.TextWrapped(statusText)
    end
    ImGui.SetNextItemWidth(core.px(220))
    local minutes = ImGui.SliderInt('Minimum duration (minutes)##longBuffDuration', cfg.minDurationMinutes, 5, 180)
    if minutes ~= cfg.minDurationMinutes then
        cfg.minDurationMinutes = math.max(5, math.min(180, tonumber(minutes) or 15))
        state.signature = nil
        state.complete = false
        state.scanning = false
        core.saveLoadout(true)
    end

    ImGui.SetNextItemWidth(90)
    local limitNow = rosterLimit()
    local newLimit = ImGui.SliderInt('Buff limit (15 recommended, max 40)##longBuffLimit', limitNow, 5, ROSTER_USER_MAX)
    if type(newLimit) == 'number' and newLimit ~= limitNow then
        cfg.maxBuffs = math.max(1, math.min(ROSTER_USER_MAX, math.floor(newLimit)))
        core.saveLoadout(true)
    end
    local autoOn = ImGui.Checkbox('Offer a recommended roster when this character has none (recommended)##longBuffAutoSuggest', cfg.autoSuggest == true)
    if autoOn ~= (cfg.autoSuggest == true) then
        cfg.autoSuggest = autoOn
        core.saveLoadout(true)
    end
    if ImGui.Button('Build suggested roster##longBuffGenerate') then
        if state.scanning then
            state.status = 'Wait for the current spellbook refresh to finish.'
        else
            state.discoveryRequested = true
            state.proposal = nil
            state.proposalOpen = false
            state.proposalOpened = false
            if state.complete then
                suggestRoster()
            else
                state.status = state.bookCacheValid
                    and 'Building suggestions from the saved spellbook list...'
                    or 'Reading your scribed spells for suggestions...'
            end
        end
    end
    ImGui.SameLine()
    if ImGui.Button('Reload scribed spells##longBuffReload') then
        plugin.requestRefresh()
    end
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('%d roster entries', #(cfg.roster or {})))
    if state.bookCacheValid and state.bookCacheCheckedAt > 0 then
        local ageMinutes = math.max(0, math.floor((os.time() - state.bookCacheCheckedAt) / 60))
        ImGui.TextDisabled(string.format('Saved spell list checked %d minute%s ago; refreshes every 15 minutes.',
            ageMinutes, ageMinutes == 1 and '' or 's'))
    elseif not state.scanning then
        if state.bookCacheCheckedAt > 0 then
            ImGui.TextDisabled('Saved spell list is older than 15 minutes; it is being refreshed.')
        else
            ImGui.TextDisabled('No saved spell list yet; the initial spellbook scan will build one.')
        end
    end
    if state.status and state.status ~= '' then ImGui.TextWrapped(state.status) end
    drawProposal()
    drawAudience()

    if #cfg.roster > 0 then
        ImGui.Spacing()
        if core.accent and core.colors then core.accent(core.colors.GOLD, 'Your Buff Roster') end
        ImGui.TextDisabled('Self-only effects are checked on you once. Single-target group buffs are checked on each living group member; group spells are tracked across the group.')
        local flags = ImGuiTableFlags and ImGuiTableFlags.RowBg or 0
        if ImGui.BeginTable('longBuffRosterTable', 4, flags) then
            ImGui.TableSetupColumn('Buff')
            ImGui.TableSetupColumn('Source')
            ImGui.TableSetupColumn('Applies to')
            ImGui.TableSetupColumn('##remove', ImGuiTableColumnFlags and ImGuiTableColumnFlags.WidthFixed or 0, core.px(58))
            ImGui.TableHeadersRow()
            local removeIndex = nil
            for index, entry in ipairs(cfg.roster) do
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                ImGui.TextWrapped(entry.spellName)
                ImGui.TableNextColumn()
                ImGui.Text(string.format('%s (%s)', entry.type == 'aa' and 'AA' or 'Spell', entry.class or '?'))
                ImGui.TableNextColumn()
                if entry.targetMode == 'single' then
                    local scope = entry.scope == 'self' and 'Self only' or 'Self + Group'
                    if ImGui.BeginCombo('##longBuffScope' .. index, scope) then
                        local _, selfPressed = ImGui.Selectable('Self only', entry.scope == 'self')
                        if selfPressed then entry.scope = 'self'; core.saveLoadout(true) end
                        local _, groupPressed = ImGui.Selectable('Self + Group', entry.scope ~= 'self')
                        if groupPressed then entry.scope = 'group'; core.saveLoadout(true) end
                        ImGui.EndCombo()
                    end
                elseif entry.targetMode == 'self' then
                    ImGui.Text('Self')
                else
                    ImGui.Text('Group spell')
                end
                ImGui.TableNextColumn()
                if ImGui.SmallButton('Remove##longBuffRemove' .. index) then removeIndex = index end
            end
            ImGui.EndTable()
            if removeIndex then
                table.remove(cfg.roster, removeIndex)
                state.candidateCursor = 1
                state.targetCursor = 1
                core.saveLoadout(true)
            end
        end
    end

    if state.complete and #state.catalog > 0 then
        ImGui.Spacing()
        if core.accent and core.colors then core.accent(core.colors.GOLD, 'Add Another Eligible Buff') end
        ImGui.TextDisabled('Manual additions are saved immediately. The automatic suggestion workflow always asks before changing your roster.')
        if ImGui.BeginChild('longBuffAvailableCandidates', 0, core.px(115), true) then
            for index, candidate in ipairs(state.catalog) do
                if not rosterContainsSpell(candidate.spellName) then
                    ImGui.PushID('longBuffCandidate' .. index)
                    ImGui.TextWrapped(string.format('%s  (%s, %d min)', candidate.spellName, candidate.class,
                        math.floor((candidate.durationSec or 0) / 60)))
                    ImGui.SameLine()
                    if ImGui.SmallButton('Add##longBuffCandidateAdd') then
                        cfg.roster[#cfg.roster + 1] = makeRosterEntry(candidate)
                        state.candidateCursor = 1
                        state.targetCursor = 1
                        state.status = candidate.spellName .. ' added to your buff roster.'
                        core.saveLoadout(true)
                    end
                    ImGui.PopID()
                end
            end
        end
        ImGui.EndChild()
    end

    if state.scanning then
        ImGui.TextDisabled(string.format('Reading spellbook: %d / %d slots', state.cursor - 1, BOOK_SLOT_MAX))
    elseif not cfg.enabled then
        if standalone then
            ImGui.TextDisabled('Standalone automatic casting is off. Enable it here; roster generation and editing do not enable casts.')
        else
            ImGui.TextDisabled('Automatic casting is off. Enable it here or use /ac longbuff on; building and editing the roster does not enable casting.')
        end
    elseif state.complete then
        if standalone then
            ImGui.TextDisabled(string.format('Discovered %d eligible spells and %d AAs. Standalone casts only while TAC is stopped, idle, and free of XTarget threats.', state.spellCount, state.aaCount))
        else
            ImGui.TextDisabled(string.format('Discovered %d eligible spells and %d AAs. Casting requires TAC running, Downtime Buffs enabled, and no combat.', state.spellCount, state.aaCount))
        end
        if #cfg.roster == 0 then ImGui.TextDisabled('The roster is empty, so no automatic long buffs will be cast.') end
        if state.noSwapGem then
            ImGui.TextDisabled(standalone
                and 'Unmemorized spells need a configured gem slot so the previous spell can be restored afterward.'
                or 'Unmemorized spells need a configured primary gem slot so TAC can restore it afterward.')
        end
        if state.lastStackQueryError then
            ImGui.TextDisabled('Some candidates were skipped because MQ did not return a stacking result.')
        end
    end
end

function plugin.onCommand(cmd, args)
    if cmd ~= 'longbuff' and cmd ~= 'autobuff' then return false end
    refresh()
    local action = args and tostring(args[2] or ''):lower() or ''
    if action == 'on' then
        setEnabled(true)
    elseif action == 'off' then
        setEnabled(false)
    elseif action == 'scan' then
        if cfg.enabled then
            beginScan(nil)
            print('\ag[Triune]\ax Long-buff spellbook and AA scan started.')
        else
            print('\ay[Triune]\ax Long buffs are off. Use /ac longbuff on first.')
        end
    elseif action == 'debug' then
        cfg.debug = not cfg.debug
        dbg.nextSnapshotAt = 0
        if cfg.debug then dlog('==== debug logging started (v%s) ====', plugin.version) else flushDebugLog(true) end
        if core and core.saveLoadout then core.saveLoadout(true) end
        print('\ag[Triune]\ax Long-buff debug log ' .. (cfg.debug and ('ON -> ' .. debugLogPath()) or 'OFF'))
        return true
    elseif action == '' or action == 'toggle' then
        setEnabled(not cfg.enabled)
    else
        print('\ay[Triune]\ax usage: /ac longbuff [on|off|toggle|scan]')
        return true
    end
    if action ~= 'scan' then
        print(string.format('\ag[Triune]\ax Long-duration buffing %s.', cfg.enabled and 'ON' or 'OFF'))
    end
    return true
end

plugin.help = {
    '  \ag/ac longbuff on|off|toggle\ax - Enable, disable, or toggle long-duration class spell and AA buffs',
    '  \ag/ac longbuff scan\ax - Re-scan the scribed class spellbook and trained class AAs',
    '  \agSettings > Plugins > Long-Duration Buffs\ax - Build a confirmed suggested roster (15 by default, up to 40) and edit it',
}

plugin.state = state
plugin.cfg = cfg
plugin.log = dlog
plugin.logChange = dlogChange
plugin.nextLongBuffCast = nextLongBuffCast
plugin.readDurationSeconds = readDurationSeconds

return plugin
