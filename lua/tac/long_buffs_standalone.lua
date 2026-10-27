---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- Standalone host for the shared long-buff roster. Casting is blocked while
-- Triune is running so the TAC and standalone cast paths cannot overlap.

local mq = require('mq')
local ImGui = require('ImGui')
local scriptDir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
local luaDir = tostring(mq.luaDir or (scriptDir .. '..\\')):gsub('[\\/]+$', '')
package.path = scriptDir .. '..\\?.lua;' .. scriptDir .. '?.lua;' .. luaDir .. '\\?.lua;' .. package.path

local sharedStore = require('tac_long_buffs_store')
local longBuffs = require('tac.long_buffs')

local function loadTable(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    if ok and type(value) == 'table' then return value end
    return nil
end

local function readCharacterData()
    local character, tag = sharedStore.characterName(mq)
    local configDir = mq.configDir or 'config'
    local loadout = loadTable(configDir .. '/triune_loadout_' .. tag .. '.lua')
        or loadTable(configDir .. '/triune_loadout.lua')
    local entry = loadout and (loadout[character] or loadout)
    local classes = type(entry) == 'table' and entry.classes or {}
    local dataPaths = {
        (mq.configDir or 'config') .. '/triune_data.lua',
        luaDir .. '\\triune_data.lua',
    }
    local spellData
    for _, path in ipairs(dataPaths) do
        spellData = loadTable(path)
        if spellData and type(spellData.spells) == 'table' then break end
        spellData = nil
    end
    return type(classes) == 'table' and classes or {}, spellData or { spells = {}, aas = {} }
end

local function durationSeconds(value)
    if type(value) == 'number' then
        if value > 10000 then return value / 1000 end
        return math.max(0, value)
    end
    local seconds
    pcall(function() seconds = tonumber(value.TotalSeconds()) end)
    if seconds and seconds > 0 then return seconds end
    local ticks
    pcall(function() ticks = tonumber(value.Ticks()) end)
    if ticks and ticks > 0 then return ticks * 6 end
    return 0
end

local classes, data = readCharacterData()
local standaloneStatus = 'Standalone buffs are disabled until enabled in the window.'
local windowOpen = true
local stopRequested = false
local pendingRestore = nil

local function readBoolean(tlo)
    local value = tlo()
    if value == true or value == 1 then return true end
    if value == false or value == 0 then return false end
    return nil
end

local function namedNpc(spawn)
    local named = false
    pcall(function()
        if spawn and spawn() and tostring(spawn.Type() or ''):lower() == 'npc'
            and spawn.Named() == true and (tonumber(spawn.PctHP()) or 0) > 0 then named = true end
    end)
    return named
end

-- Snapshot of what the character is doing. Me.Casting.ID() is nil (not 0)
-- while idle, so a missing value counts as "not casting".
local function readState()
    local s = { ok = true, casting = 0, moving = false, combat = false, named = false }
    local ok = pcall(function()
        s.casting = tonumber(mq.TLO.Me.Casting.ID()) or 0
        s.moving = readBoolean(function() return mq.TLO.Me.Moving() end) == true
        s.combat = readBoolean(function() return mq.TLO.Me.Combat() end) == true
    end)
    if not ok then s.ok = false return s end
    if namedNpc(mq.TLO.Target) then s.named = true end
    for index = 1, 20 do
        local id = 0
        if not pcall(function() id = tonumber(mq.TLO.Me.XTarget(index).ID()) or 0 end) then
            s.ok = false
            return s
        end
        if id > 0 then
            local spawn = mq.TLO.Spawn(id)
            local kind = ''
            pcall(function() kind = tostring(spawn.Type() or ''):lower() end)
            if kind ~= 'pc' then
                s.combat = true
                if namedNpc(spawn) then s.named = true end
            end
        end
    end
    return s
end

-- Strict check for spellbook work: no combat, no movement, not casting.
local function safeIdle()
    local s = readState()
    return s.ok and not s.combat and not s.named and not s.moving and s.casting == 0
end

-- Casting a memorized buff is fine mid-fight unless a named NPC is engaged.
local function safeToCast()
    local s = readState()
    if not s.ok or s.named or s.moving or s.casting ~= 0 then return false, false end
    return true, s.combat
end

local combatCastAllowed = false
local function threatened()
    local s = readState()
    return not s.ok or s.named or (not combatCastAllowed and s.combat)
end

local function spawnFor(id)
    local spawn
    local ok = pcall(function()
        spawn = mq.TLO.Spawn(id)
        if not spawn or not spawn() or (tonumber(spawn.ID()) or 0) ~= id then spawn = nil end
    end)
    return ok and spawn or nil
end

local function targetAlive(id)
    if id == (tonumber(mq.TLO.Me.ID()) or 0) then return true end
    local spawn = spawnFor(id)
    if not spawn then return false end
    local hp
    pcall(function() hp = tonumber(spawn.PctHP()) end)
    return hp == nil or hp > 0
end

local function buffActive(id, spellName)
    local target = nil
    if id == (tonumber(mq.TLO.Me.ID()) or 0) then
        target = mq.TLO.Me
    else
        target = spawnFor(id)
    end
    if not target then return nil end

    local ok, active = pcall(function()
        local buff = target.Buff(spellName)
        if buff and buff() then return true end
        if id == (tonumber(mq.TLO.Me.ID()) or 0) then
            local song = mq.TLO.Me.Song(spellName)
            if song and song() then return true end
        end
        return false
    end)
    if not ok or (active ~= true and active ~= false) then return nil end
    return active
end

local function targetInRange(spellName, id)
    if id == (tonumber(mq.TLO.Me.ID()) or 0) then return true end
    local spawn = spawnFor(id)
    if not spawn then return false end
    local distance, range
    pcall(function() distance = tonumber(spawn.Distance3D()) or tonumber(spawn.Distance()) end)
    pcall(function() range = tonumber(mq.TLO.Spell(spellName).Range()) end)
    if not distance then return false end
    if not range or range <= 0 then range = 100 end
    return distance <= range + 2
end

local hostRuntime = {
    isCasting = function()
        local castingId
        local ok = pcall(function() castingId = tonumber(mq.TLO.Me.Casting.ID()) end)
        if not ok or castingId == nil then return nil end
        return castingId > 0
    end,
    isSpawnAlive = targetAlive,
    isTargetInRange = targetInRange,
    buffActive = buffActive,
    getPrimarySpellForGem = function(slot)
        local spell
        pcall(function() spell = mq.TLO.Me.Gem(slot)() end)
        return type(spell) == 'string' and spell or nil
    end,
}
local host = {
    standalone = true,
    mq = mq,
    ImGui = ImGui,
    DATA = data,
    myClasses = classes,
    ctrl = { running = true, downtime_buffing = true },
    runtime = hostRuntime,
    parseDurationSec = durationSeconds,
    cleanSpellName = function(name) return type(name) == 'string' and name:match('^%s*(.-)%s*$') or '' end,
    getNumGems = function()
        local count = 12
        pcall(function() count = tonumber(mq.TLO.Me.NumGems()) or count end)
        return count
    end,
    px = function(value) return value end,
    colors = { GOLD = { 1.0, 0.70, 0.54, 1.0 } },
    accent = function(color, text) ImGui.TextColored(color[1], color[2], color[3], color[4], text) end,
    saveLoadout = function() longBuffs.saveSharedSettings() end,
}

local function tacRunning()
local ok, script = pcall(function() return mq.TLO.Lua.Script('triune') end)
if not ok then return nil end
if not script or not script() then return false end
local status
local statusOk = pcall(function() status = tostring(script.Status() or '') end)
if not statusOk then return nil end
if status == 'RUNNING' then return true end
if status == 'STOPPED' or status == '' then return false end
return nil
end

local function waitFor(predicate, timeoutMs, abortOnThreat)
local elapsed = 0
while elapsed <= timeoutMs do
    local ok, ready = pcall(predicate)
    if ok and ready then return true end
    if abortOnThreat and (tacRunning() ~= false or threatened()) then return false end
    mq.doevents()
    mq.delay(100)
    elapsed = elapsed + 100
end
return false
end

local function bookSlotFor(spellName)
local slot
pcall(function() slot = tonumber(mq.TLO.Me.Book(spellName)()) end)
if slot and slot > 0 then return slot end
local wanted = tostring(spellName):lower()
for index = 1, 1120 do
    local name
    pcall(function() name = mq.TLO.Me.Book(index)() end)
    if type(name) == 'string' and name:lower() == wanted then return index end
end
return nil
end

local function gemSpell(slot)
local name
pcall(function() name = mq.TLO.Me.Gem(slot)() end)
if type(name) ~= 'string' or name == '' or name == 'NULL' then return nil end
return name
end

local function clearCursor()
local cursorId = 0
pcall(function() cursorId = tonumber(mq.TLO.Cursor.ID()) or 0 end)
if cursorId <= 0 then return end
for _ = 1, 255 do
    mq.cmd('/autoinventory')
    mq.delay(50)
    pcall(function() cursorId = tonumber(mq.TLO.Cursor.ID()) or 0 end)
    if cursorId <= 0 then return end
end
end

local function unmemorizeGem(slot)
if not gemSpell(slot) then return true end
mq.cmdf('/notify CastSpellWnd CSPW_Spell%d rightmouseup', slot - 1)
return waitFor(function() return gemSpell(slot) == nil end, 1500, true)
end

local function closeSpellbook()
local isOpen = false
pcall(function() isOpen = mq.TLO.Window('SpellBookWnd').Open() == true end)
if isOpen then mq.cmd('/notify SpellBookWnd SBW_DoneButton leftmouseup') end
end

local function memorizeGem(slot, spellName)
if not safeIdle() then return false, 'Not safe to memorize while active, moving, casting, or threatened.' end
if tacRunning() ~= false then return false, 'TAC is running or its status is unknown.' end
clearCursor()
local current = gemSpell(slot)
if current and current:lower() == spellName:lower() then return true end
local targetBookSlot = bookSlotFor(spellName)
if not targetBookSlot then return false, 'Spell is not scribed: ' .. spellName end

for index = 1, host.getNumGems() do
    local existing = gemSpell(index)
    if index ~= slot and existing and existing:lower() == spellName:lower() then
        if not unmemorizeGem(index) then return false, 'Could not move duplicate spell out of gem ' .. index end
        break
    end
end
if not unmemorizeGem(slot) then return false, 'Could not clear gem ' .. slot end

local bookOpen = false
pcall(function() bookOpen = mq.TLO.Window('SpellBookWnd').Open() == true end)
if not bookOpen then mq.cmd('/book') end
if not waitFor(function() return mq.TLO.Window('SpellBookWnd').Open() == true end, 3000, true) then
    closeSpellbook()
    return false, 'Could not open the spellbook.'
end

local pageSize = 0
for index = 0, 24 do
    local childName
    pcall(function() childName = mq.TLO.Window('SpellBookWnd').Child('SBW_Spell' .. index).Name() end)
    if not childName then break end
    pageSize = pageSize + 1
end
if pageSize == 0 then pageSize = 8 end

local currentPage = nil
for index = 0, pageSize - 1 do
    local shown
    pcall(function() shown = mq.TLO.Window('SpellBookWnd').Child('SBW_Spell' .. index).Text() end)
    if type(shown) == 'string' and shown ~= '' and shown ~= 'NULL' then
        local shownSlot = bookSlotFor(shown)
        if shownSlot then currentPage = math.ceil(shownSlot / pageSize); break end
    end
end
if not currentPage then
    for _ = 1, 40 do
        mq.cmd('/notify SpellBookWnd SBW_PageDown_Button leftmouseup')
        mq.delay(100)
        if not safeIdle() then closeSpellbook(); return false, 'Casting interrupted spellbook navigation.' end
    end
    currentPage = 1
end

local targetPage = math.ceil(targetBookSlot / pageSize)
local delta = targetPage - currentPage
local button = delta > 0 and 'SBW_PageUp_Button' or 'SBW_PageDown_Button'
for _ = 1, math.abs(delta) do
    mq.cmdf('/notify SpellBookWnd %s leftmouseup', button)
    mq.delay(150)
    if not safeIdle() then closeSpellbook(); return false, 'Casting interrupted spellbook navigation.' end
end

mq.cmdf('/notify SpellBookWnd SBW_Spell%d leftmouseup', (targetBookSlot - 1) % pageSize)
mq.delay(350)
if tacRunning() ~= false or not safeIdle() then
    clearCursor()
    closeSpellbook()
    return false, 'Casting interrupted before the spell could be memorized.'
end
mq.cmdf('/notify CastSpellWnd CSPW_Spell%d leftmouseup', slot - 1)
if not waitFor(function() return mq.TLO.Window('CastingWindow').Open() == true end, 3000, true) then
    closeSpellbook()
    return false, 'Spell memorization did not start.'
end
if not waitFor(function() return mq.TLO.Window('CastingWindow').Open() ~= true end, 30000, true) then
    pcall(function() mq.cmd('/stopcast') end)
    closeSpellbook()
    return false, 'Spell memorization timed out or was interrupted.'
end
mq.delay(300)
closeSpellbook()
clearCursor()
local memorized = gemSpell(slot)
if memorized and memorized:lower() == spellName:lower() then return true end
return false, 'Spell was not verified in gem ' .. slot
end

local function restoreGem(slot, previousSpell)
if previousSpell then
    if tacRunning() ~= false or not safeIdle() then
        pendingRestore = { slot = slot, spell = previousSpell }
        standaloneStatus = 'Could not restore gem ' .. slot .. ' until standalone casting is safe.'
        return false
    end
    local ok, reason = memorizeGem(slot, previousSpell)
    if not ok then
        pendingRestore = { slot = slot, spell = previousSpell }
        standaloneStatus = 'Could not restore gem ' .. slot .. ' yet: ' .. tostring(reason)
    else
        pendingRestore = nil
    end
    return ok
end
return unmemorizeGem(slot)
end

local function waitForCast(targetId, spellName)
if not waitFor(function() return hostRuntime.isCasting() end, 1500, false) then
    return buffActive(targetId, spellName) == true
end
if not waitFor(function() return not hostRuntime.isCasting() end, 60000, true) then return false end
return buffActive(targetId, spellName) == true
end

local function restoreTarget(targetId)
if targetId and targetId > 0 then
    mq.cmdf('/target id %d', targetId)
else
    mq.cmd('/target clear')
end
end

local function castBuffNow(entry, targetId, inCombat)
if mq.TLO.Me.Sitting() == true or mq.TLO.Me.Ducking() == true then
    mq.cmd('/stand')
    mq.delay(300)
end
local oldTarget = tonumber(mq.TLO.Target.ID()) or 0
local selfId = tonumber(mq.TLO.Me.ID()) or 0
local spell = mq.TLO.Spell(entry.spell)
local targetMode = ''
pcall(function() targetMode = tostring(spell.TargetType() or ''):lower() end)
local groupCast = targetMode:find('group', 1, true)
    or targetMode:find('area', 1, true)
    or targetMode:find('ae', 1, true)
local castTarget = groupCast and selfId or targetId
if not castTarget or castTarget <= 0 then castTarget = selfId end

if castTarget ~= selfId then
    mq.cmdf('/target id %d', castTarget)
    if not waitFor(function() return (tonumber(mq.TLO.Target.ID()) or 0) == castTarget end, 1500, true) then
        restoreTarget(oldTarget)
        standaloneStatus = 'Could not target the missing-buff group member.'
        return false
    end
end

if entry.autoBuffType == 'aa' then
    local aaId
    pcall(function() aaId = tonumber(mq.TLO.Me.AltAbility(entry.name).ID()) end)
    if not aaId or aaId <= 0 then
        restoreTarget(oldTarget)
        standaloneStatus = 'Could not resolve AA ID for ' .. tostring(entry.name)
        return false
    end
    mq.cmdf('/alt act %d', aaId)
    local castOk = waitFor(function() return buffActive(targetId, entry.spell) == true end, 5000, true)
    restoreTarget(oldTarget)
    standaloneStatus = castOk
        and ('Cast long-duration AA buff: ' .. tostring(entry.name))
        or ('AA buff could not be verified: ' .. tostring(entry.name))
    return castOk
end

local gem
pcall(function() gem = tonumber(mq.TLO.Me.Gem(entry.spell)()) end)
local swapped = false
local previousSpell = nil
if not gem or gem <= 0 then
    gem = tonumber(entry.gem) or 0
    if gem <= 0 then
        restoreTarget(oldTarget)
        standaloneStatus = 'No usable spell gem for ' .. tostring(entry.spell)
        return false
    end
    previousSpell = gemSpell(gem)
    local memmed, reason = memorizeGem(gem, entry.spell)
    if not memmed then
        restoreGem(gem, previousSpell)
        restoreTarget(oldTarget)
        standaloneStatus = tostring(reason)
        if pendingRestore then
            standaloneStatus = standaloneStatus .. '; gem ' .. pendingRestore.slot .. ' restoration is pending.'
        end
        return false
    end
    swapped = true
end

if not inCombat and not safeIdle() then
    if swapped then restoreGem(gem, previousSpell) end
    restoreTarget(oldTarget)
    standaloneStatus = 'Casting aborted because the character is no longer idle.'
    if pendingRestore then
        standaloneStatus = standaloneStatus .. ' Gem ' .. pendingRestore.slot .. ' restoration is pending.'
    end
    return false
end
mq.cmdf('/cast %d', gem)
local castOk = waitForCast(targetId, entry.spell)
local restoreOk = true
if swapped then restoreOk = restoreGem(gem, previousSpell) end
restoreTarget(oldTarget)
if not castOk then
    standaloneStatus = 'Spell cast was interrupted: ' .. tostring(entry.spell)
    if pendingRestore then
        standaloneStatus = standaloneStatus .. '; gem ' .. pendingRestore.slot .. ' restoration is pending.'
    end
    return false
end
if not restoreOk then return false end
standaloneStatus = 'Cast long-duration buff: ' .. tostring(entry.spell)
return true
end

local function castBuff(entry, targetId)
if tacRunning() ~= false then
    standaloneStatus = 'Casting blocked: TAC is running or its status is unknown.'
    return false
end
local canCast, inCombat = safeToCast()
if not canCast then
    standaloneStatus = 'Casting paused: moving, already casting, or a named NPC is engaged.'
    return false
end
combatCastAllowed = inCombat
local ok, result = pcall(castBuffNow, entry, targetId, inCombat)
combatCastAllowed = false
if not ok then
    standaloneStatus = 'Cast error: ' .. tostring(result)
    return false
end
return result
end

local function drawWindow()
local open, visible = ImGui.Begin('Long-Duration Buffs##standaloneLongBuffs', windowOpen)
windowOpen = open
if visible then
    host.accent(host.colors.GOLD, 'Long-Duration Buffs')
    ImGui.TextWrapped('Standalone buffing recasts roster buffs whenever you or a group member loses one, including mid-fight, but never while a named NPC is engaged. It is blocked while TAC runs; inside TAC use the Buffs button instead. Roster changes are shared with TAC.')
    if #classes == 0 then
        ImGui.TextWrapped('No three-class loadout was found for this character. Discovery suggestions require TAC to have a saved class trio; existing roster entries can still be edited.')
    else
        ImGui.TextDisabled('Classes used for discovery: ' .. table.concat(classes, ', '))
    end
    if tacRunning() == true then
        ImGui.TextWrapped('TAC is running; standalone casts are blocked to prevent duplicate buffs.')
    elseif tacRunning() == nil then
        ImGui.TextWrapped('TAC status could not be determined; standalone casts are blocked fail-closed.')
    end
    if standaloneStatus and standaloneStatus ~= '' then ImGui.TextWrapped(standaloneStatus) end
    longBuffs.onDrawSettings()
end
ImGui.End()
return open
end

mq.imgui.init('TACLongBuffStandalone', drawWindow)
mq.unbind('/longbuff')
mq.bind('/longbuff', function(...)
    local args = { ... }
    local action = tostring(args[1] or ''):lower()
    if action == 'show' then
        windowOpen = true
    elseif action == 'hide' then
        windowOpen = false
    elseif action == 'stop' then
        stopRequested = true
    elseif action == 'reload' or action == 'scan' then
        longBuffs.requestRefresh()
    elseif action == 'on' or action == 'off' or action == 'toggle' or action == 'debug' then
        longBuffs.onCommand('longbuff', { 'longbuff', action })
    else
        print('\ay[Long Buffs]\ax usage: /longbuff [show|hide|on|off|toggle|reload|debug|stop]')
    end
end)
longBuffs.onInit(host)
longBuffs.setCastingEnabled(true)
local ok, err = xpcall(function()
    while true do
        mq.doevents()
        longBuffs.onTick()
        longBuffs.logChange('standalone', 'STANDALONE: %s', tostring(standaloneStatus))
        if stopRequested then
            if not pendingRestore then break end
            if tacRunning() == false and safeIdle()
                and restoreGem(pendingRestore.slot, pendingRestore.spell) then
                standaloneStatus = 'Restored gem ' .. pendingRestore.slot .. '; standalone script stopped.'
            else
                standaloneStatus = 'Stopping is waiting for gem ' .. pendingRestore.slot .. ' to be safely restored.'
            end
        elseif pendingRestore then
            if tacRunning() == false and safeIdle()
                and restoreGem(pendingRestore.slot, pendingRestore.spell) then
                standaloneStatus = 'Restored spell to gem ' .. pendingRestore.slot
            end
        elseif longBuffs.cfg.enabled then
            local tacState = tacRunning()
            if tacState ~= false then
                standaloneStatus = 'Casting blocked: TAC is running or its status is unknown.'
            else
                local canCast, inCombat = safeToCast()
                if canCast then
                    local entry, targetId = longBuffs.nextLongBuffCast(inCombat)
                    if entry and targetId then castBuff(entry, targetId) end
                else
                    standaloneStatus = 'Casting paused: moving, already casting, or a named NPC is engaged.'
                end
            end
        end
        mq.delay(100)
    end
end, debug.traceback)

mq.unbind('/longbuff')
longBuffs.onDestroy()
if not ok then
    print('\ar[Long Buffs]\ax standalone script stopped: ' .. tostring(err))
end
