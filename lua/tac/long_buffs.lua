---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- ============================================================================
-- TAC/lua/tac/long_buffs.lua — Long-Duration Class Buffs Plugin
-- ============================================================================
-- Uses class spell data plus the character's scribed spells and trained class
-- AAs. Spell casts are handed to the core downtime-buff path so temporary gem
-- swaps use the existing aggro checks and restore the configured primary gem.
-- ============================================================================

local plugin = {
    id                 = 'long_buffs',
    name               = 'Long-Duration Buffs',
    version            = '1.1.1-pre.1',
    author             = 'Triune',
    description        = 'Casts scribed class buffs and trained class AAs with long-duration beneficial effects on self and group.',
    defaultEnabled     = true,
    tickInterval       = 0.5,
    runOutOfCombatOnly = true,
    hasThread          = false,
}

local core, ctrl, mq, runtime, DATA, ImGui = nil, nil, nil, nil, nil, nil
local cfg = {
    enabled = false,
    minDurationMinutes = 15,
    roster = {},
}

local BOOK_SLOT_MAX = 720
local BOOK_SLOTS_PER_TICK = 120
local CATALOG_REFRESH_SEC = 30
local RETRY_SEC = 15
local SUGGESTED_ROSTER_SIZE = 15

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
    proposal = nil,
    proposalOpen = false,
    proposalOpened = false,
    stackUnknownCount = 0,
    stackConflictCount = 0,
    duplicateCount = 0,
    status = '',
}

local attempted = {}

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
    attempted = {}
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
    return key ~= '' and bookNames[key] == true
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

local function publishCatalog(classes, playerLevel)
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
    state.nextScanAt = os.clock() + CATALOG_REFRESH_SEC
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

local function stacksWith(candidateName, otherName)
    local result = nil
    local ok = pcall(function()
        local spell = mq.TLO.Spell(candidateName)
        if spell and spell() and spell.StacksWith then
            result = spell.StacksWith(otherName)
        end
    end)
    if not ok then return nil end
    if result == true or result == 1 or tostring(result):lower() == 'true' then return true end
    if result == false or result == 0 or tostring(result):lower() == 'false' then return false end
    return nil
end

local function suggestRoster()
    local chosen = {}
    local proposal = {}
    local selectedCount = #(cfg.roster or {})
    local unknownCount = 0
    local conflictCount = 0
    local duplicateCount = 0

    for _, entry in ipairs(cfg.roster or {}) do
        if entry.spellName and entry.spellName ~= '' then
            chosen[#chosen + 1] = entry.spellName
        end
    end

    for _, candidate in ipairs(state.catalog) do
        if selectedCount >= SUGGESTED_ROSTER_SIZE then break end
        if rosterContainsSpell(candidate.spellName) then
            duplicateCount = duplicateCount + 1
        else
            local compatible = true
            for _, existingSpell in ipairs(chosen) do
                local stacks = stacksWith(candidate.spellName, existingSpell)
                if stacks == false then
                    compatible = false
                    break
                elseif stacks == nil then
                    unknownCount = unknownCount + 1
                end
            end
            if compatible then
                local entry = makeRosterEntry(candidate)
                entry.selected = true
                proposal[#proposal + 1] = entry
                chosen[#chosen + 1] = candidate.spellName
                selectedCount = selectedCount + 1
            else
                conflictCount = conflictCount + 1
            end
        end
    end

    state.proposal = proposal
    state.stackUnknownCount = unknownCount
    state.stackConflictCount = conflictCount
    state.duplicateCount = duplicateCount
    state.discoveryRequested = false
    state.proposalOpened = false
    state.status = string.format('%d suggested buff%s ready for review.', #proposal, #proposal == 1 and '' or 's')
    if #proposal > 0 then
        state.proposalOpen = true
    else
        state.proposalOpen = false
        if #(cfg.roster or {}) >= SUGGESTED_ROSTER_SIZE then
            state.status = 'The roster already has 15 or more entries; remove one before generating more suggestions.'
        elseif #state.catalog == 0 then
            state.status = 'No eligible scribed class buffs or trained class AAs were found.'
        else
            state.status = 'No additional non-duplicate, stacking-compatible suggestions were found.'
        end
    end
end

local function stepScan()
    if (not cfg.enabled and not state.discoveryRequested) or not mq or not mq.TLO then return end
    local classes = classNames()
    local playerLevel = 0
    pcall(function() playerLevel = tonumber(mq.TLO.Me.Level()) or 0 end)
    if playerLevel <= 0 then return end

    local signature = classSignature(classes, playerLevel)
    if state.signature ~= signature or (state.complete and os.clock() >= state.nextScanAt) then
        beginScan(signature)
    end
    if not state.scanning then return end

    local last = math.min(BOOK_SLOT_MAX, state.cursor + BOOK_SLOTS_PER_TICK - 1)
    for slotIndex = state.cursor, last do
        local name = readBookName(slotIndex)
        if name then state.bookNames[nameKey(name)] = true end
    end
    state.cursor = last + 1

    if state.cursor > BOOK_SLOT_MAX then
        if #classes == 0 then
            state.scanning = false
            state.complete = true
            state.nextScanAt = os.clock() + CATALOG_REFRESH_SEC
            state.discoveryRequested = false
            state.status = 'Could not discover the character class list. The buff roster was not changed.'
            return
        end
        publishCatalog(classes, playerLevel)
        if state.discoveryRequested then suggestRoster() end
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

local function canStack(spellName, targetId)
    local can = nil
    local ok = pcall(function()
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.StacksSpawn then
            can = spell.StacksSpawn(targetId)
        end
    end)
    if not ok then
        state.lastStackQueryError = 'StacksSpawn query failed for ' .. spellName
        return false
    end
    if can == true or can == 1 then return true end
    if can == false or can == 0 then return false end
    state.lastStackQueryError = 'StacksSpawn returned no result for ' .. spellName
    return false
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
    return nil
end

local function nextLongBuffCast()
    refresh()
    if not cfg.enabled or not state.complete or not runtime or not mq or not ctrl or #(cfg.roster or {}) == 0 then return nil end
    if ctrl.downtime_buffing == false or ctrl.running ~= true then return nil end
    if runtime.isCasting and runtime.isCasting() then return nil end

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
                gem = tempGemForSpell(candidate.spellName)
                if not gem then state.noSwapGem = true end
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
                        if isTargetAlive(targetId, selfId) and isInRange(candidate, targetId) then
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
                        state.candidateCursor = candidateIndex + 1
                        state.targetCursor = 1
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
                        local active = buffIsActive(targetId, candidate.spellName)
                        if isTargetAlive(targetId, selfId)
                            and active == false
                            and (not lastAttempt or (now - lastAttempt) >= RETRY_SEC)
                            and isInRange(candidate, targetId)
                            and canStack(candidate.spellName, targetId) then
                            attempted[key] = now
                            state.candidateCursor = candidateIndex
                            state.targetCursor = targetIndex < targetEnd and targetIndex + 1 or 1
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
    for key, at in pairs(attempted) do
        if now - at > 300 then attempted[key] = nil end
    end
    return nil
end

function plugin.onTick()
    refresh()
    stepScan()
end

function plugin.onInit(coreApi)
    core = coreApi
    refresh()
    if runtime then runtime.nextLongBuffCast = nextLongBuffCast end
end

function plugin.onDestroy()
    if runtime and runtime.nextLongBuffCast == nextLongBuffCast then
        runtime.nextLongBuffCast = nil
    end
end

function plugin.onLoadSettings(settings)
    if type(settings) ~= 'table' then return end
    if settings.enabled ~= nil then cfg.enabled = settings.enabled == true end
    local minutes = tonumber(settings.minDurationMinutes)
    if minutes then cfg.minDurationMinutes = math.max(5, math.min(180, math.floor(minutes))) end
    cfg.roster = {}
    local seen = {}
    for _, entry in ipairs(type(settings.roster) == 'table' and settings.roster or {}) do
        if type(entry) == 'table'
            and (entry.type == 'spell' or entry.type == 'aa')
            and type(entry.name) == 'string'
            and entry.name ~= ''
            and type(entry.spellName) == 'string'
            and entry.spellName ~= '' then
            local key = nameKey(entry.spellName)
            if key ~= '' and not seen[key] then
                seen[key] = true
                cfg.roster[#cfg.roster + 1] = {
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
    if cfg.enabled then beginScan(nil) end
end

function plugin.onSaveSettings()
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
        minDurationMinutes = cfg.minDurationMinutes,
        roster = roster,
    }
end

local function setEnabled(value)
    cfg.enabled = value == true
    if cfg.enabled then
        beginScan(nil)
    else
        state.scanning = false
        state.complete = false
        state.catalog = {}
        attempted = {}
    end
    if core and core.saveLoadout then core.saveLoadout(true) end
end

local function closeProposal()
    state.proposalOpen = false
    state.proposalOpened = false
    state.proposal = nil
end

local function acceptProposal()
    local added = 0
    for _, entry in ipairs(state.proposal or {}) do
        if entry.selected and #cfg.roster < SUGGESTED_ROSTER_SIZE and not rosterContainsSpell(entry.spellName) then
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
    state.status = string.format('Added %d suggested buff%s. Automatic casting remains %s.',
        added, added == 1 and '' or 's', cfg.enabled and 'enabled' or 'off')
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
        ImGui.TextWrapped('Review the proposed buffs. Nothing changes until you confirm. The roster is limited to 15 generated entries; you can manually add more afterward.')
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

function plugin.onDrawSettings()
    refresh()
    if not core or not ImGui or not ctrl then return end
    if core.accent and core.colors then core.accent(core.colors.GOLD, 'Long-Duration Buffs') end
    ImGui.TextDisabled('Build an editable roster from eligible scribed class buffs and trained class AAs across your three classes.')

    local enabled = ImGui.Checkbox('Automatically cast long buffs##longBuffEnabled', cfg.enabled == true)
    if enabled ~= (cfg.enabled == true) then setEnabled(enabled) end

    ImGui.SetNextItemWidth(core.px(220))
    local minutes = ImGui.SliderInt('Minimum duration (minutes)##longBuffDuration', cfg.minDurationMinutes, 5, 180)
    if minutes ~= cfg.minDurationMinutes then
        cfg.minDurationMinutes = math.max(5, math.min(180, tonumber(minutes) or 15))
        if cfg.enabled then beginScan(nil) end
        core.saveLoadout(true)
    end

    if ImGui.Button('Build suggested roster (up to 15)##longBuffGenerate') then
        if state.scanning then
            state.status = 'Wait for the current spellbook scan to finish.'
        else
            state.discoveryRequested = true
            state.proposal = nil
            state.proposalOpen = false
            state.proposalOpened = false
            state.status = 'Scanning your spellbook and trained AAs for suggestions...'
            beginScan(nil)
        end
    end
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('%d roster entries', #(cfg.roster or {})))
    if state.status and state.status ~= '' then ImGui.TextWrapped(state.status) end
    drawProposal()

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

    if not cfg.enabled then
        ImGui.TextDisabled('Automatic casting is off. Enable it here or use /ac longbuff on; building and editing the roster does not enable casting.')
    elseif state.scanning then
        ImGui.TextDisabled(string.format('Reading spellbook: %d / %d slots', state.cursor - 1, BOOK_SLOT_MAX))
    elseif state.complete then
        ImGui.TextDisabled(string.format('Discovered %d eligible spells and %d AAs. Casting requires TAC running, Downtime Buffs enabled, and no combat.', state.spellCount, state.aaCount))
        if #cfg.roster == 0 then ImGui.TextDisabled('The roster is empty, so no automatic long buffs will be cast.') end
        if state.noSwapGem then
            ImGui.TextDisabled('Unmemorized spells need a configured primary gem slot so TAC can restore it afterward.')
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
    '  \agSettings > Plugins > Long-Duration Buffs\ax - Build a confirmed suggested roster of up to 15 buffs and edit it',
}

plugin.state = state
plugin.cfg = cfg
plugin.nextLongBuffCast = nextLongBuffCast
plugin.readDurationSeconds = readDurationSeconds

return plugin
