local ADDON_NAME = ...

local TARGET_AURA_NAME = "Wild Imp"
local MAX_AURA_SLOTS = 255

local HAND_OF_GULDAN_SPELL_ID = 105174
local IMPLOSION_SPELL_ID = 196277
local POWER_SIPHON_SPELL_ID = 264130
local CALL_DREADSTALKERS_SPELL_ID = 104316
local CALL_DREADSTALKERS_CAST_SPELL_ID = 334727
local GRIMOIRE_FELGUARD_SPELL_ID = 111898
local SUMMON_DEMONIC_TYRANT_SPELL_ID = 265187
local SUMMON_DEMONIC_TYRANT_CAST_SPELL_ID = 334585
local DEMONOLOGY_SPEC_ID = 266

local MAX_HAND_OF_GULDAN_IMPS = 3
local IMPS_REMOVED_PER_IMPLOSION = 6
local IMPS_REMOVED_PER_POWER_SIPHON = 2
local TYRANT_BASE_WINDOW_DURATION = 15
local TYRANT_REIGN_BONUS_DURATION = 5

local IMP_START_ENERGY = 100
local IMP_ENERGY_PER_CAST = 20
local IMP_CASTS_PER_WILD_IMP = IMP_START_ENERGY / IMP_ENERGY_PER_CAST
local IMP_FEL_FIREBOLT_CAST_TIME = 2
local IMP_FIRST_CAST_DELAY = 0.9
local IMP_HARD_TIMEOUT = 20
local INNER_DEMON_INTERVAL = 12

local FALLBACK_NAMES = {
    wildImpAura = TARGET_AURA_NAME,
    innerDemons = "Inner Demons",
    toHellAndBack = "To Hell and Back",
    grimoireFelguard = "Grimoire: Felguard",
    grimoireImpLord = "Grimoire: Imp Lord",
    grimoireFelRavager = "Grimoire: Fel Ravager",
    singeMagic = "Singe Magic",
    spellLock = "Spell Lock",
    reignOfTyranny = "Reign of Tyranny",
    powerSiphon = "Power Siphon",
    summonDoomguard = "Summon Doomguard",
}

local defaults = {
    implosionThreshold = 6,
    implosionCooldown = 15,
    powerSiphonCooldown = 30,
    dreadstalkersCooldown = 20,
    grimoireCooldown = 120,
    tyrantCooldown = 60,
    doomguardCooldown = 120,
    showImplosionOverlay = true,
    showPowerSiphonOverlay = true,
    showDreadstalkersOverlay = true,
    showGrimoireOverlay = true,
    showTyrantOverlay = true,
    showDoomguardOverlay = true,
    learnedNames = {},
    learnedSpellIDs = {},
}

local db
local trackedItemFrames = {}
local GetSpellNameByID
local GetTrackedItemFrame
local RebuildLocalizedNameCaches
local GetLearnedSpellID

local activeGroups = {}
local pendingHoG = {}
local talentState = {
    innerDemons = false,
    toHellAndBack = false,
    reignOfTyranny = false,
}

local nextInnerDemonAt
local nextImplosionReadyAt = 0
local lastEstimateUpdate = GetTime()
local startupGraceUntil = 0
local localizedNames = {}
local grimoireTrackedSpellNames = {}
local grimoireSlotSpellNames = {}
local tyrantWindowUntil = 0
local tyrantHoGCount = 0

local trackedSpellConfigs = {
    [IMPLOSION_SPELL_ID] = {
        cooldownKey = "implosionCooldown",
        enabledKey = "showImplosionOverlay",
        showCount = true,
    },
    [POWER_SIPHON_SPELL_ID] = {
        cooldownKey = "powerSiphonCooldown",
        enabledKey = "showPowerSiphonOverlay",
        showCount = true,
    },
    [CALL_DREADSTALKERS_SPELL_ID] = {
        cooldownKey = "dreadstalkersCooldown",
        enabledKey = "showDreadstalkersOverlay",
    },
    [GRIMOIRE_FELGUARD_SPELL_ID] = {
        cooldownKey = "grimoireCooldown",
        enabledKey = "showGrimoireOverlay",
    },
    [SUMMON_DEMONIC_TYRANT_SPELL_ID] = {
        cooldownKey = "tyrantCooldown",
        enabledKey = "showTyrantOverlay",
    },
}

local trackedCooldownState = {
    [POWER_SIPHON_SPELL_ID] = { activated = false, readyAt = 0 },
    [CALL_DREADSTALKERS_SPELL_ID] = { activated = false, readyAt = 0 },
    [GRIMOIRE_FELGUARD_SPELL_ID] = { activated = false, readyAt = 0 },
    [SUMMON_DEMONIC_TYRANT_SPELL_ID] = { activated = false, readyAt = 0 },
}

local lastGrimoireSlotSpellName

local trackedSpellAliases = {
    [CALL_DREADSTALKERS_CAST_SPELL_ID] = CALL_DREADSTALKERS_SPELL_ID,
    [SUMMON_DEMONIC_TYRANT_CAST_SPELL_ID] = SUMMON_DEMONIC_TYRANT_SPELL_ID,
}

local function CopyDefaults(src, dst)
    for key, value in pairs(src) do
        if type(value) == "table" then
            dst[key] = dst[key] or {}
            CopyDefaults(value, dst[key])
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
end

local function EnsureDB()
    ImpTrackerDB = ImpTrackerDB or {}
    CopyDefaults(defaults, ImpTrackerDB)
    db = ImpTrackerDB
    RebuildLocalizedNameCaches()

    local learnedPowerSiphonSpellID = GetLearnedSpellID("powerSiphon")
    if learnedPowerSiphonSpellID and learnedPowerSiphonSpellID ~= POWER_SIPHON_SPELL_ID then
        trackedSpellAliases[learnedPowerSiphonSpellID] = POWER_SIPHON_SPELL_ID
    end
end

local function GetLearnedName(key)
    if db and db.learnedNames and db.learnedNames[key] and db.learnedNames[key] ~= "" then
        return db.learnedNames[key]
    end

    return FALLBACK_NAMES[key]
end

local function RememberName(key, value)
    if not db or not db.learnedNames or not value or value == "" then
        return
    end

    db.learnedNames[key] = value
end

GetLearnedSpellID = function(key)
    if not db or not db.learnedSpellIDs then
        return nil
    end

    local spellID = tonumber(db.learnedSpellIDs[key])
    if spellID and spellID > 0 then
        return spellID
    end

    return nil
end

local function RememberSpellID(key, spellID)
    spellID = tonumber(spellID)
    if not db or not db.learnedSpellIDs or not spellID or spellID <= 0 then
        return
    end

    db.learnedSpellIDs[key] = spellID
end

RebuildLocalizedNameCaches = function()
    localizedNames.wildImpAura = GetLearnedName("wildImpAura")
    localizedNames.innerDemons = GetLearnedName("innerDemons")
    localizedNames.toHellAndBack = GetLearnedName("toHellAndBack")
    localizedNames.reignOfTyranny = GetLearnedName("reignOfTyranny")
    localizedNames.grimoireFelguard = GetSpellNameByID(GRIMOIRE_FELGUARD_SPELL_ID) or GetLearnedName("grimoireFelguard")
    localizedNames.grimoireImpLord = GetLearnedName("grimoireImpLord")
    localizedNames.grimoireFelRavager = GetLearnedName("grimoireFelRavager")
    localizedNames.singeMagic = GetLearnedName("singeMagic")
    localizedNames.spellLock = GetLearnedName("spellLock")
    localizedNames.powerSiphon = GetSpellNameByID(POWER_SIPHON_SPELL_ID) or GetLearnedName("powerSiphon")
    localizedNames.summonDoomguard = GetLearnedName("summonDoomguard")

    wipe(grimoireTrackedSpellNames)
    wipe(grimoireSlotSpellNames)

    grimoireTrackedSpellNames[localizedNames.grimoireFelguard] = true
    grimoireTrackedSpellNames[localizedNames.grimoireImpLord] = true
    grimoireTrackedSpellNames[localizedNames.grimoireFelRavager] = true

    for name in pairs(grimoireTrackedSpellNames) do
        grimoireSlotSpellNames[name] = true
    end

    grimoireSlotSpellNames[localizedNames.singeMagic] = true
    grimoireSlotSpellNames[localizedNames.spellLock] = true
end

local function GetDoomguardSpellID()
    return GetLearnedSpellID("summonDoomguard")
end

local function EnsureDoomguardTracking(spellID)
    spellID = tonumber(spellID)
    if not spellID or spellID <= 0 then
        return nil
    end

    if not trackedSpellConfigs[spellID] then
        trackedSpellConfigs[spellID] = {
            cooldownKey = "doomguardCooldown",
            enabledKey = "showDoomguardOverlay",
        }
    end

    if not trackedCooldownState[spellID] then
        trackedCooldownState[spellID] = { activated = false, readyAt = 0 }
    end

    RememberSpellID("summonDoomguard", spellID)
    local spellName = GetSpellNameByID(spellID)
    if spellName then
        RememberName("summonDoomguard", spellName)
        RebuildLocalizedNameCaches()
    end

    return spellID
end

local function GetTrackedReadySpellIDs()
    local spellIDs = {
        CALL_DREADSTALKERS_SPELL_ID,
        GRIMOIRE_FELGUARD_SPELL_ID,
        SUMMON_DEMONIC_TYRANT_SPELL_ID,
    }

    local doomguardSpellID = GetDoomguardSpellID()
    if doomguardSpellID then
        table.insert(spellIDs, doomguardSpellID)
    end

    return spellIDs
end

local function IsOverlayEnabled(spellID)
    local config = trackedSpellConfigs[spellID]
    if not config or not config.enabledKey then
        return true
    end

    if db and db[config.enabledKey] ~= nil then
        return db[config.enabledKey]
    end

    return defaults[config.enabledKey] ~= false
end

local function GetPlayerSpecID()
    if not GetSpecialization or not GetSpecializationInfo then
        return nil
    end

    local specIndex = GetSpecialization()
    if not specIndex then
        return nil
    end

    return GetSpecializationInfo(specIndex)
end

local function IsDemonologySpecActive()
    return GetPlayerSpecID() == DEMONOLOGY_SPEC_ID
end

local function GetSpellTextureByID(spellID)
    if not spellID then
        return nil
    end

    if C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and texture then
            return texture
        end
    end

    if GetSpellTexture then
        local ok, texture = pcall(GetSpellTexture, spellID)
        if ok and texture then
            return texture
        end
    end

    return nil
end

GetSpellNameByID = function(spellID)
    if not spellID then
        return nil
    end

    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellID)
    end

    if GetSpellInfo then
        return GetSpellInfo(spellID)
    end

    return nil
end

local function RefreshTalentState()
    talentState.innerDemons = false
    talentState.toHellAndBack = false
    talentState.reignOfTyranny = false

    if not IsDemonologySpecActive() then
        return
    end

    if not (
        C_ClassTalents and C_ClassTalents.GetActiveConfigID and
        C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeNodes and
        C_Traits.GetNodeInfo and C_Traits.GetEntryInfo and C_Traits.GetDefinitionInfo
    ) then
        return
    end

    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        return
    end

    local configInfo = C_Traits.GetConfigInfo(configID)
    local treeIDs = configInfo and configInfo.treeIDs
    if not treeIDs then
        return
    end

    for _, treeID in ipairs(treeIDs) do
        local nodeIDs = C_Traits.GetTreeNodes(treeID)
        if nodeIDs then
            for _, nodeID in ipairs(nodeIDs) do
                local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                local activeEntryID = nodeInfo and nodeInfo.activeEntry and nodeInfo.activeEntry.entryID

                if not activeEntryID and nodeInfo and nodeInfo.activeEntryID then
                    activeEntryID = nodeInfo.activeEntryID
                end

                if not activeEntryID and nodeInfo and nodeInfo.entryIDs and nodeInfo.currentRank and nodeInfo.currentRank > 0 and #nodeInfo.entryIDs == 1 then
                    activeEntryID = nodeInfo.entryIDs[1]
                end

                if activeEntryID then
                    local entryInfo = C_Traits.GetEntryInfo(configID, activeEntryID)
                    local definitionID = entryInfo and entryInfo.definitionID
                    if definitionID then
                        local definitionInfo = C_Traits.GetDefinitionInfo(definitionID)
                        local spellID = definitionInfo and (definitionInfo.overrideSpellID or definitionInfo.spellID)
                        local spellName = GetSpellNameByID(spellID)

                        if spellName and (spellName == localizedNames.innerDemons or spellName == FALLBACK_NAMES.innerDemons) then
                            talentState.innerDemons = true
                            RememberName("innerDemons", spellName)
                        elseif spellName and (spellName == localizedNames.toHellAndBack or spellName == FALLBACK_NAMES.toHellAndBack) then
                            talentState.toHellAndBack = true
                            RememberName("toHellAndBack", spellName)
                        elseif spellName and (spellName == localizedNames.reignOfTyranny or spellName == FALLBACK_NAMES.reignOfTyranny) then
                            talentState.reignOfTyranny = true
                            RememberName("reignOfTyranny", spellName)
                        elseif spellName and (spellName == localizedNames.powerSiphon or spellName == FALLBACK_NAMES.powerSiphon) then
                            RememberName("powerSiphon", spellName)
                            RememberSpellID("powerSiphon", spellID)
                            trackedSpellAliases[spellID] = POWER_SIPHON_SPELL_ID
                        elseif spellName and (spellName == localizedNames.summonDoomguard or spellName == FALLBACK_NAMES.summonDoomguard) then
                            EnsureDoomguardTracking(spellID)
                        end
                    end
                end
            end
        end
    end

    RebuildLocalizedNameCaches()
end

local function HasInnerDemons()
    return IsDemonologySpecActive() and talentState.innerDemons
end

local function HasToHellAndBack()
    return IsDemonologySpecActive() and talentState.toHellAndBack
end

local function HasReignOfTyranny()
    return IsDemonologySpecActive() and talentState.reignOfTyranny
end

local function NormalizeTrackedCastSpellID(spellID)
    local normalized = trackedSpellAliases[spellID] or spellID
    local spellName = GetSpellNameByID(normalized)

    if spellName and grimoireTrackedSpellNames[spellName] then
        return GRIMOIRE_FELGUARD_SPELL_ID
    end

    return normalized
end

local function NormalizeTrackedItemSpellID(spellID)
    local normalized = trackedSpellAliases[spellID] or spellID
    local spellName = GetSpellNameByID(normalized)

    if spellName and grimoireSlotSpellNames[spellName] then
        return GRIMOIRE_FELGUARD_SPELL_ID
    end

    return normalized
end

local function GetEstimatedImplosionRemaining(now)
    now = now or GetTime()
    return math.max(0, (nextImplosionReadyAt or 0) - now)
end

local function ResetEstimatedCooldowns()
    nextImplosionReadyAt = 0
    lastGrimoireSlotSpellName = nil
    tyrantWindowUntil = 0
    tyrantHoGCount = 0

    for spellID, state in pairs(trackedCooldownState) do
        state.activated = false
        state.readyAt = 0
    end
end

local function GetTyrantWindowDuration()
    return TYRANT_BASE_WINDOW_DURATION + (HasReignOfTyranny() and TYRANT_REIGN_BONUS_DURATION or 0)
end

local function IsTyrantWindowActive(now)
    now = now or GetTime()
    return IsDemonologySpecActive() and (tyrantWindowUntil or 0) > now
end

local function StartTyrantWindow(now)
    now = now or GetTime()
    tyrantWindowUntil = now + GetTyrantWindowDuration()
    tyrantHoGCount = 0
end

local function ClearTyrantWindow()
    tyrantWindowUntil = 0
    tyrantHoGCount = 0
end

local function UpdateTyrantWindowState(now)
    if not IsTyrantWindowActive(now) and ((tyrantWindowUntil or 0) > 0 or (tyrantHoGCount or 0) > 0) then
        ClearTyrantWindow()
    end
end

local function GetEstimatedTrackedCooldownRemaining(spellID, now)
    local state = trackedCooldownState[spellID]
    if not state or not state.activated then
        return nil
    end

    now = now or GetTime()
    return math.max(0, (state.readyAt or 0) - now)
end

local function IsEstimatedTrackedCooldownReady(spellID, now)
    local remaining = GetEstimatedTrackedCooldownRemaining(spellID, now)
    return remaining ~= nil and remaining <= 0
end

local function StartEstimatedTrackedCooldown(spellID, now)
    local config = trackedSpellConfigs[spellID]
    local state = trackedCooldownState[spellID]
    if not config or not state then
        return
    end

    now = now or GetTime()
    state.activated = true
    state.readyAt = now + (db[config.cooldownKey] or defaults[config.cooldownKey] or 0)
end

local function GetImpEnergyDecayPerSecond()
    local hasteMultiplier = 1 + ((GetHaste() or 0) / 100)
    return (IMP_ENERGY_PER_CAST / IMP_FEL_FIREBOLT_CAST_TIME) * hasteMultiplier
end

local function AddGroup(count, source, spawnTime)
    local amount = math.max(0, tonumber(count) or 0)
    if amount <= 0 then
        return
    end

    local spawn = tonumber(spawnTime) or GetTime()
    table.insert(activeGroups, {
        count = amount,
        source = source or "unknown",
        spawn = spawn,
        energy = IMP_START_ENERGY,
        energyStartAt = spawn + IMP_FIRST_CAST_DELAY,
        expiresAt = spawn + IMP_HARD_TIMEOUT,
    })
end

local function AdvanceCombatDecay(now)
    now = now or GetTime()

    local previous = lastEstimateUpdate or now
    local dt = now - previous
    lastEstimateUpdate = now

    if dt <= 0 then
        return
    end

    if dt > 1.5 then
        dt = 1.5
        previous = now - dt
    end

    if not UnitAffectingCombat("player") then
        return
    end

    local decayPerSecond = GetImpEnergyDecayPerSecond()
    for i = 1, #activeGroups do
        local group = activeGroups[i]
        local energyStartAt = group.energyStartAt or group.spawn or now
        local decayWindowStart = math.max(previous, energyStartAt)
        if now > decayWindowStart then
            local activeDt = now - decayWindowStart
            group.energy = math.max(0, (group.energy or IMP_START_ENERGY) - (decayPerSecond * activeDt))
        end
    end
end

local function ClearExpiredGroups(now)
    now = now or GetTime()

    for i = #activeGroups, 1, -1 do
        local group = activeGroups[i]
        if now >= (group.expiresAt or 0) or (group.energy or IMP_START_ENERGY) <= 0 or (group.count or 0) <= 0 then
            table.remove(activeGroups, i)
        end
    end
end

local function GetEstimatedImpCount(now)
    ClearExpiredGroups(now)

    local total = 0
    for i = 1, #activeGroups do
        total = total + (activeGroups[i].count or 0)
    end

    return total
end

local function BuildRemovalOrder()
    local indices = {}
    for i = 1, #activeGroups do
        indices[i] = i
    end

    table.sort(indices, function(a, b)
        local groupA = activeGroups[a]
        local groupB = activeGroups[b]
        local startA = groupA and (groupA.energyStartAt or groupA.spawn) or 0
        local startB = groupB and (groupB.energyStartAt or groupB.spawn) or 0

        if startA ~= startB then
            return startA < startB
        end

        local spawnA = groupA and groupA.spawn or 0
        local spawnB = groupB and groupB.spawn or 0
        return spawnA < spawnB
    end)

    return indices
end

local function RemoveImpCount(count, now)
    local toRemove = math.max(0, tonumber(count) or 0)
    if toRemove <= 0 then
        return 0
    end

    ClearExpiredGroups(now)

    local removedTotal = 0
    local orderedIndices = BuildRemovalOrder()
    for _, index in ipairs(orderedIndices) do
        local group = activeGroups[index]
        if group and toRemove > 0 then
            local removed = math.min(group.count or 0, toRemove)
            group.count = (group.count or 0) - removed
            removedTotal = removedTotal + removed
            toRemove = toRemove - removed
        end

        if toRemove <= 0 then
            break
        end
    end

    ClearExpiredGroups(now)
    return removedTotal
end

local function ResetEstimate(actualCount, now)
    wipe(activeGroups)

    local count = math.max(0, tonumber(actualCount) or 0)
    if count <= 0 then
        return
    end

    local current = now or GetTime()
    local hasteMultiplier = 1 + ((GetHaste() or 0) / 100)
    local impliedLifetime = (IMP_CASTS_PER_WILD_IMP * IMP_FEL_FIREBOLT_CAST_TIME) / math.max(0.1, hasteMultiplier)
    local assumedAge = math.max(0, math.min(impliedLifetime * 0.45, impliedLifetime - 0.5))
    AddGroup(count, "sync", current - assumedAge)
end

local function ResyncEstimate(actualCount, now)
    now = now or GetTime()
    local count = math.max(0, tonumber(actualCount) or 0)

    if count == 0 then
        wipe(activeGroups)
        return
    end

    local estimated = GetEstimatedImpCount(now)
    if estimated == count then
        return
    end

    if estimated == 0 then
        ResetEstimate(count, now)
        return
    end

    if estimated < count then
        AddGroup(count - estimated, "sync", now)
    else
        RemoveImpCount(estimated - count, now)
    end
end

local function GetWildImpAuraSnapshot()
    if (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") then
        return 0, nil, nil
    end

    local learnedAuraSpellID = GetLearnedSpellID("wildImpAura")
    if learnedAuraSpellID and AuraUtil and AuraUtil.FindAuraBySpellID then
        local ok, name, icon, count, _, _, _, _, _, spellID = pcall(AuraUtil.FindAuraBySpellID, learnedAuraSpellID, "player", "HELPFUL")
        if ok and name then
            RememberName("wildImpAura", name)
            RememberSpellID("wildImpAura", spellID or learnedAuraSpellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(count) or 0), icon, spellID or learnedAuraSpellID
        end
    end

    if AuraUtil and AuraUtil.FindAuraByName then
        local ok, name, icon, count, _, _, _, _, _, spellID = pcall(AuraUtil.FindAuraByName, localizedNames.wildImpAura, "player", "HELPFUL")
        if ok and name then
            RememberName("wildImpAura", name)
            RememberSpellID("wildImpAura", spellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(count) or 0), icon, spellID
        end
    end

    if localizedNames.wildImpAura ~= TARGET_AURA_NAME and AuraUtil and AuraUtil.FindAuraByName then
        local ok, name, icon, count, _, _, _, _, _, spellID = pcall(AuraUtil.FindAuraByName, TARGET_AURA_NAME, "player", "HELPFUL")
        if ok and name then
            RememberName("wildImpAura", name)
            RememberSpellID("wildImpAura", spellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(count) or 0), icon, spellID
        end
    end

    local ok, name, icon, count, _, _, _, _, _, spellID = pcall(UnitBuff, "player", localizedNames.wildImpAura)
    if ok and name then
        RememberName("wildImpAura", name)
        RememberSpellID("wildImpAura", spellID)
        RebuildLocalizedNameCaches()
        return math.max(0, tonumber(count) or 0), icon, spellID
    end

    if localizedNames.wildImpAura ~= TARGET_AURA_NAME then
        local fallbackOk, fallbackName, fallbackIcon, fallbackCount, _, _, _, _, _, fallbackSpellID = pcall(UnitBuff, "player", TARGET_AURA_NAME)
        if fallbackOk and fallbackName then
            RememberName("wildImpAura", fallbackName)
            RememberSpellID("wildImpAura", fallbackSpellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(fallbackCount) or 0), fallbackIcon, fallbackSpellID
        end
    end

    for i = 1, MAX_AURA_SLOTS do
        local okIndex, auraName, auraIcon, auraCount, _, _, _, _, _, auraSpellID = pcall(UnitBuff, "player", i)
        if not okIndex or not auraName then
            break
        end

        if auraSpellID == learnedAuraSpellID or auraName == localizedNames.wildImpAura or auraName == TARGET_AURA_NAME then
            RememberName("wildImpAura", auraName)
            RememberSpellID("wildImpAura", auraSpellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(auraCount) or 0), auraIcon, auraSpellID
        end
    end

    return 0, nil, nil
end

local function PrintStatus(now)
    now = now or GetTime()
    local estimated = GetEstimatedImpCount(now)
    local auraCount, _, auraSpellID = GetWildImpAuraSnapshot()

    print(string.format("|cff9d7dffImpTracker:|r Estimated imps = %d", estimated))
    print(string.format("|cff9d7dffImpTracker:|r Active groups = %d", #activeGroups))
    print(string.format("|cff9d7dffImpTracker:|r Spec = %s", IsDemonologySpecActive() and "Demonology" or "Other"))
    print(string.format("|cff9d7dffImpTracker:|r Inner Demons = %s | To Hell and Back = %s | Reign of Tyranny = %s", talentState.innerDemons and "on" or "off", talentState.toHellAndBack and "on" or "off", talentState.reignOfTyranny and "on" or "off"))
    print(string.format("|cff9d7dffImpTracker:|r Implosion threshold = %s | Implosion CD = %ss | Ready in %.1fs", tostring(db.implosionThreshold or defaults.implosionThreshold), tostring(db.implosionCooldown or defaults.implosionCooldown), GetEstimatedImplosionRemaining(now)))
    print(string.format("|cff9d7dffImpTracker:|r Power Siphon ready in %.1fs | Dreadstalkers ready in %.1fs | Grimoire ready in %.1fs | Tyrant ready in %.1fs", GetEstimatedTrackedCooldownRemaining(POWER_SIPHON_SPELL_ID, now) or 0, GetEstimatedTrackedCooldownRemaining(CALL_DREADSTALKERS_SPELL_ID, now) or 0, GetEstimatedTrackedCooldownRemaining(GRIMOIRE_FELGUARD_SPELL_ID, now) or 0, GetEstimatedTrackedCooldownRemaining(SUMMON_DEMONIC_TYRANT_SPELL_ID, now) or 0))
    print(string.format("|cff9d7dffImpTracker:|r Tyrant window = %s | HoG during Tyrant = %d | Ends in %.1fs", IsTyrantWindowActive(now) and "active" or "idle", tyrantHoGCount or 0, math.max(0, (tyrantWindowUntil or 0) - now)))

    local doomguardSpellID = GetDoomguardSpellID()
    if doomguardSpellID then
        print(string.format("|cff9d7dffImpTracker:|r Doomguard spellID=%s | Ready in %.1fs", tostring(doomguardSpellID), GetEstimatedTrackedCooldownRemaining(doomguardSpellID, now) or 0))
    end

    print(string.format("|cff9d7dffImpTracker:|r Wild Imp model = %d casts at %.1fs base cast, %.1f energy per cast", IMP_CASTS_PER_WILD_IMP, IMP_FEL_FIREBOLT_CAST_TIME, IMP_ENERGY_PER_CAST))

    if auraCount > 0 then
        print(string.format("|cff9d7dffImpTracker:|r Aura count=%s spellID=%s", tostring(auraCount), tostring(auraSpellID or "?")))
    elseif (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") then
        print("|cff9d7dffImpTracker:|r In combat: using estimate only.")
    else
        print("|cff9d7dffImpTracker:|r Wild Imp aura count assumed to be 0.")
    end
end

local function ProcessInnerDemon(now)
    if not HasInnerDemons() then
        nextInnerDemonAt = nil
        return
    end

    if not UnitAffectingCombat("player") then
        nextInnerDemonAt = nil
        return
    end

    if not nextInnerDemonAt then
        nextInnerDemonAt = now + INNER_DEMON_INTERVAL
        return
    end

    while now >= nextInnerDemonAt do
        AddGroup(1, "inner", nextInnerDemonAt)
        nextInnerDemonAt = nextInnerDemonAt + INNER_DEMON_INTERVAL
    end
end

local function UpdateEstimateState(now)
    now = now or GetTime()

    if not IsDemonologySpecActive() then
        wipe(activeGroups)
        nextInnerDemonAt = nil
        return
    end

    AdvanceCombatDecay(now)
    ClearExpiredGroups(now)
    ProcessInnerDemon(now)
    ClearExpiredGroups(now)
end

GetTrackedItemFrame = function(spellID)
    local cachedFrame = trackedItemFrames[spellID]
    if cachedFrame and cachedFrame.GetSpellID and NormalizeTrackedItemSpellID(cachedFrame:GetSpellID()) == spellID then
        return cachedFrame
    end

    trackedItemFrames[spellID] = nil

    if not EssentialCooldownViewer or not EssentialCooldownViewer.GetItemFrames then
        return nil
    end

    local itemFrames = EssentialCooldownViewer:GetItemFrames()
    if not itemFrames then
        return nil
    end

    for _, itemFrame in ipairs(itemFrames) do
        local itemSpellID = itemFrame.GetSpellID and itemFrame:GetSpellID()
        if NormalizeTrackedItemSpellID(itemSpellID) == spellID then
            trackedItemFrames[spellID] = itemFrame
            return itemFrame
        end
    end

    return nil
end

local function EnsureTrackedOverlay(spellID)
    if not IsOverlayEnabled(spellID) then
        return nil
    end

    local itemFrame = GetTrackedItemFrame(spellID)
    if not itemFrame then
        return nil
    end

    local overlayKey = "ImpTrackerOverlay" .. tostring(spellID)
    local overlay = itemFrame[overlayKey]

    if not overlay then
        local anchor = itemFrame.Icon or itemFrame

        overlay = CreateFrame("Frame", nil, itemFrame)
        overlay:SetAllPoints(anchor)
        overlay:SetFrameStrata(itemFrame:GetFrameStrata())
        overlay:SetFrameLevel((anchor.GetFrameLevel and anchor:GetFrameLevel()) or (itemFrame:GetFrameLevel() + 8))
        overlay:EnableMouse(false)

        local border = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
        border:SetPoint("TOPLEFT", overlay, "TOPLEFT", -5, 5)
        border:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 5, -5)
        border:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 11,
        })
        border:SetBackdropBorderColor(0.20, 1.00, 0.40, 0)
        overlay.Border = border

        if trackedSpellConfigs[spellID] and trackedSpellConfigs[spellID].showCount then
            local countText = overlay:CreateFontString(nil, "OVERLAY")
            countText:SetFont("Fonts\\FRIZQT__.TTF", 30, "THICKOUTLINE")
            countText:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 6, -1)
            countText:SetJustifyH("RIGHT")
            countText:SetText("0")
            overlay.CountText = countText
        end

        if spellID == SUMMON_DEMONIC_TYRANT_SPELL_ID then
            local countText = overlay:CreateFontString(nil, "OVERLAY")
            countText:SetFont("Fonts\\FRIZQT__.TTF", 26, "THICKOUTLINE")
            countText:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 6, -1)
            countText:SetJustifyH("RIGHT")
            countText:SetText("0")
            countText:Hide()
            overlay.WindowCountText = countText

            local hogIcon = overlay:CreateTexture(nil, "OVERLAY")
            hogIcon:SetSize(16, 16)
            hogIcon:SetPoint("RIGHT", countText, "LEFT", -3, 0)
            hogIcon:SetTexture(GetSpellTextureByID(HAND_OF_GULDAN_SPELL_ID))
            hogIcon:Hide()
            overlay.HoGIcon = hogIcon
        end

        itemFrame[overlayKey] = overlay
    end

    if trackedSpellConfigs[spellID] and trackedSpellConfigs[spellID].showCount and itemFrame.ChargeCount then
        itemFrame.ChargeCount:SetAlpha(0)
    end

    return overlay, itemFrame
end

local function CleanupStaleOverlays()
    if not EssentialCooldownViewer or not EssentialCooldownViewer.GetItemFrames then
        return
    end

    local itemFrames = EssentialCooldownViewer:GetItemFrames()
    if not itemFrames then
        return
    end

    for _, itemFrame in ipairs(itemFrames) do
        local rawSpellID = itemFrame.GetSpellID and itemFrame:GetSpellID()
        local activeSpellID = NormalizeTrackedItemSpellID(rawSpellID)
        local hideChargeCount = false

        for spellID, config in pairs(trackedSpellConfigs) do
            local overlayKey = "ImpTrackerOverlay" .. tostring(spellID)
            local overlay = itemFrame[overlayKey]

            if overlay then
                if activeSpellID == spellID and itemFrame:IsShown() and IsDemonologySpecActive() and IsOverlayEnabled(spellID) then
                    if config.showCount then
                        hideChargeCount = true
                    end
                else
                    overlay:Hide()
                end
            end
        end

        if itemFrame.ChargeCount then
            itemFrame.ChargeCount:SetAlpha(hideChargeCount and 0 or 1)
        end
    end
end

local function ObserveGrimoireSlot(now)
    local itemFrame = GetTrackedItemFrame(GRIMOIRE_FELGUARD_SPELL_ID)
    if not itemFrame or not itemFrame.GetSpellID then
        lastGrimoireSlotSpellName = nil
        return
    end

    local rawSpellID = itemFrame:GetSpellID()
    local rawSpellName = GetSpellNameByID(rawSpellID)
    local grimoireState = trackedCooldownState[GRIMOIRE_FELGUARD_SPELL_ID]

    if grimoireState and (not grimoireState.activated) and lastGrimoireSlotSpellName and grimoireTrackedSpellNames[lastGrimoireSlotSpellName] and (rawSpellName == localizedNames.singeMagic or rawSpellName == localizedNames.spellLock or rawSpellName == FALLBACK_NAMES.singeMagic or rawSpellName == FALLBACK_NAMES.spellLock) then
        StartEstimatedTrackedCooldown(GRIMOIRE_FELGUARD_SPELL_ID, now)
    end

    lastGrimoireSlotSpellName = rawSpellName
end

local function UpdateCountOverlay(spellID, estimated, mode, now)
    if not IsOverlayEnabled(spellID) then
        return
    end

    local overlay, itemFrame = EnsureTrackedOverlay(spellID)
    if not overlay or not itemFrame then
        return
    end

    if not itemFrame:IsShown() or not IsDemonologySpecActive() then
        overlay:Hide()
        return
    end

    local count = math.max(0, tonumber(estimated) or 0)
    local countText = overlay.CountText
    local border = overlay.Border

    overlay:Show()
    countText:SetText(tostring(count))

    if itemFrame.ChargeCount then
        itemFrame.ChargeCount:SetAlpha(0)
    end

    if mode == "ready" then
        local pulse = 0.70 + (0.30 * math.abs(math.sin((now or GetTime()) * 5.5)))
        countText:SetTextColor(0.92, 1.00, 0.95)
        border:SetBackdropBorderColor(0.20, 1.00, 0.42, 0.75 + (0.25 * pulse))
    elseif mode == "building" then
        countText:SetTextColor(1.00, 0.88, 0.56)
        border:SetBackdropBorderColor(0.20, 1.00, 0.42, 0)
    elseif mode == "offspec" then
        countText:SetTextColor(0.55, 0.55, 0.60)
        border:SetBackdropBorderColor(0.20, 1.00, 0.42, 0)
    else
        countText:SetTextColor(0.84, 0.96, 1.00)
        border:SetBackdropBorderColor(0.20, 1.00, 0.42, 0)
    end
end

local function UpdateImplosionOverlay(estimated, mode, now)
    UpdateCountOverlay(IMPLOSION_SPELL_ID, estimated, mode, now)
end

local function UpdatePowerSiphonOverlay(estimated, mode, now)
    UpdateCountOverlay(POWER_SIPHON_SPELL_ID, estimated, mode, now)
end

local function UpdateTrackedReadyOverlay(spellID, now)
    if not IsOverlayEnabled(spellID) then
        local itemFrame = GetTrackedItemFrame(spellID)
        if itemFrame then
            local overlay = itemFrame["ImpTrackerOverlay" .. tostring(spellID)]
            if overlay then
                overlay:Hide()
            end
        end
        return
    end

    local overlay, itemFrame = EnsureTrackedOverlay(spellID)
    if not overlay or not itemFrame then
        return
    end

    if not itemFrame:IsShown() or not IsDemonologySpecActive() then
        overlay:Hide()
        return
    end

    overlay:Show()

    local border = overlay.Border
    if IsEstimatedTrackedCooldownReady(spellID, now) then
        local pulse = 0.70 + (0.30 * math.abs(math.sin((now or GetTime()) * 5.5)))
        border:SetBackdropBorderColor(0.20, 1.00, 0.42, 0.75 + (0.25 * pulse))
    else
        border:SetBackdropBorderColor(0.20, 1.00, 0.42, 0)
    end
end

local function UpdateTyrantWindowOverlay(now)
    if not IsOverlayEnabled(SUMMON_DEMONIC_TYRANT_SPELL_ID) then
        return
    end

    local overlay, itemFrame = EnsureTrackedOverlay(SUMMON_DEMONIC_TYRANT_SPELL_ID)
    if not overlay or not itemFrame then
        return
    end

    local countText = overlay.WindowCountText
    local hogIcon = overlay.HoGIcon
    if not countText or not hogIcon then
        return
    end

    if not itemFrame:IsShown() or not IsDemonologySpecActive() or not IsTyrantWindowActive(now) then
        countText:Hide()
        hogIcon:Hide()
        return
    end

    countText:SetText(tostring(math.max(0, tonumber(tyrantHoGCount) or 0)))
    countText:SetTextColor(0.92, 1.00, 0.95)
    hogIcon:SetTexture(GetSpellTextureByID(HAND_OF_GULDAN_SPELL_ID))
    countText:Show()
    hogIcon:Show()
end

local function GetStatusDetail(estimated, threshold, remaining)
    if estimated >= threshold and remaining <= 0 then
        return "IMPLOSION READY", "ready"
    end

    if estimated >= threshold and remaining > 0 then
        return string.format("CD %.1fs", remaining), "building"
    end

    local missing = math.max(0, threshold - estimated)
    if remaining > 0 and estimated > 0 then
        return string.format("Need %d | CD %.1fs", missing, remaining), "tracking"
    end

    if missing > 0 then
        return string.format("Need %d more", missing), "tracking"
    end

    return "Tracking", "tracking"
end

local function GetPowerSiphonMode(estimated, remaining)
    if estimated >= IMPS_REMOVED_PER_POWER_SIPHON and remaining <= 0 then
        return "ready"
    end

    if remaining > 0 then
        return estimated >= IMPS_REMOVED_PER_POWER_SIPHON and "building" or "tracking"
    end

    if estimated > 0 then
        return "building"
    end

    return "tracking"
end

local function EnsureAllTrackedOverlays()
    EnsureTrackedOverlay(IMPLOSION_SPELL_ID)
    EnsureTrackedOverlay(POWER_SIPHON_SPELL_ID)

    for _, spellID in ipairs(GetTrackedReadySpellIDs()) do
        EnsureTrackedOverlay(spellID)
    end
end

local function UpdateAllReadyOverlays(now)
    for _, spellID in ipairs(GetTrackedReadySpellIDs()) do
        UpdateTrackedReadyOverlay(spellID, now)
    end
end

local function ResetTrackerState(clearGroups)
    if clearGroups then
        wipe(activeGroups)
    end

    wipe(pendingHoG)
    nextInnerDemonAt = nil
    ResetEstimatedCooldowns()
    lastEstimateUpdate = GetTime()
end

local function UpdateDisplay()
    if not db then
        return
    end

    local now = GetTime()
    UpdateEstimateState(now)
    UpdateTyrantWindowState(now)
    ObserveGrimoireSlot(now)
    CleanupStaleOverlays()

    if not IsDemonologySpecActive() then
        wipe(activeGroups)
        wipe(pendingHoG)
        nextInnerDemonAt = nil
        ClearTyrantWindow()
        UpdateImplosionOverlay(0, "offspec", now)
        UpdatePowerSiphonOverlay(0, "offspec", now)
        UpdateAllReadyOverlays(now)
        UpdateTyrantWindowOverlay(now)
        return
    end

    local auraCount = 0
    if not ((InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player")) then
        auraCount = GetWildImpAuraSnapshot()
        ResyncEstimate(auraCount or 0, now)
        if (auraCount or 0) <= 0 and now >= (startupGraceUntil or 0) then
            wipe(activeGroups)
        end
    elseif now >= (startupGraceUntil or 0) then
        ClearExpiredGroups(now)
    end

    local estimated = GetEstimatedImpCount(now)
    local threshold = db.implosionThreshold or defaults.implosionThreshold
    local remaining = GetEstimatedImplosionRemaining(now)
    local _, mode = GetStatusDetail(estimated, threshold, remaining)
    local powerSiphonRemaining = GetEstimatedTrackedCooldownRemaining(POWER_SIPHON_SPELL_ID, now) or 0
    local powerSiphonMode = GetPowerSiphonMode(estimated, powerSiphonRemaining)

    UpdateImplosionOverlay(estimated, mode == "tracking" and (estimated > 0 and "building" or "tracking") or mode, now)
    UpdatePowerSiphonOverlay(estimated, powerSiphonMode, now)
    UpdateAllReadyOverlays(now)
    UpdateTyrantWindowOverlay(now)
end

local optionsPanel
local optionsCategory
local overlayOptionEntries = {
    { key = "showImplosionOverlay", label = function() return GetSpellNameByID(IMPLOSION_SPELL_ID) or "Implosion" end },
    { key = "showPowerSiphonOverlay", label = function() return localizedNames.powerSiphon or FALLBACK_NAMES.powerSiphon end },
    { key = "showDreadstalkersOverlay", label = function() return GetSpellNameByID(CALL_DREADSTALKERS_SPELL_ID) or "Call Dreadstalkers" end },
    { key = "showGrimoireOverlay", label = function() return localizedNames.grimoireFelguard or FALLBACK_NAMES.grimoireFelguard end },
    { key = "showTyrantOverlay", label = function() return GetSpellNameByID(SUMMON_DEMONIC_TYRANT_SPELL_ID) or "Summon Demonic Tyrant" end },
    { key = "showDoomguardOverlay", label = function() return localizedNames.summonDoomguard or FALLBACK_NAMES.summonDoomguard end },
}

local function RefreshOptionsPanel()
    if not optionsPanel or not optionsPanel.checkButtons then
        return
    end

    EnsureDB()
    RebuildLocalizedNameCaches()

    for _, option in ipairs(overlayOptionEntries) do
        local checkButton = optionsPanel.checkButtons[option.key]
        if checkButton then
            checkButton:SetChecked(db[option.key] ~= false)
            if checkButton.Label then
                checkButton.Label:SetText(option.label())
            end
        end
    end
end

local function EnsureOptionsPanel()
    if optionsPanel then
        return optionsPanel
    end

    optionsPanel = CreateFrame("Frame", ADDON_NAME .. "OptionsPanel")
    optionsPanel.name = "ImpTracker"
    optionsPanel.checkButtons = {}

    local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ImpTracker")

    local subtitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetWidth(620)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Choose which cooldown viewer icons ImpTracker is allowed to enhance.")

    local anchor = subtitle
    for _, option in ipairs(overlayOptionEntries) do
        local checkButton = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
        checkButton:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -2, -12)

        local label = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("LEFT", checkButton, "RIGHT", 4, 1)
        label:SetText(option.label())
        checkButton.Label = label

        checkButton:SetScript("OnClick", function(self)
            EnsureDB()
            db[option.key] = self:GetChecked() and true or false
            UpdateDisplay()
        end)

        optionsPanel.checkButtons[option.key] = checkButton
        anchor = checkButton
    end

    optionsPanel:SetScript("OnShow", RefreshOptionsPanel)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsPanel, "ImpTracker")
        Settings.RegisterAddOnCategory(optionsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(optionsPanel)
    end

    return optionsPanel
end

local function OpenOptionsPanel()
    local panel = EnsureOptionsPanel()
    RefreshOptionsPanel()

    if Settings and optionsCategory and optionsCategory.GetID and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategory:GetID())
        return
    end

    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

SLASH_WILDIMPTRACKER1 = "/wit"
SLASH_WILDIMPTRACKER2 = "/itr"
SlashCmdList["WILDIMPTRACKER"] = function(msg)
    EnsureDB()
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")

    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")
    arg = string.lower(arg or "")

    if cmd == "clear" then
        ResetTrackerState(true)
        print("|cff9d7dffImpTracker:|r Estimate cleared.")
    elseif cmd == "status" or cmd == "scan" then
        RefreshTalentState()
        PrintStatus()
    elseif cmd == "threshold" then
        local value = tonumber(arg)
        if value then
            db.implosionThreshold = math.max(1, math.min(40, math.floor(value)))
            print("|cff9d7dffImpTracker:|r Implosion threshold set to " .. tostring(db.implosionThreshold) .. ".")
        end
    elseif cmd == "implodecd" then
        local seconds = tonumber(arg)
        if seconds then
            db.implosionCooldown = math.max(0, math.min(60, seconds))
            print("|cff9d7dffImpTracker:|r Implosion cooldown estimate set to " .. tostring(db.implosionCooldown) .. "s.")
        end
    elseif cmd == "siphoncd" then
        local seconds = tonumber(arg)
        if seconds then
            db.powerSiphonCooldown = math.max(0, math.min(60, seconds))
            print("|cff9d7dffImpTracker:|r Power Siphon cooldown estimate set to " .. tostring(db.powerSiphonCooldown) .. "s.")
        end
    elseif cmd == "doomguardcd" then
        local seconds = tonumber(arg)
        if seconds then
            db.doomguardCooldown = math.max(0, math.min(300, seconds))
            print("|cff9d7dffImpTracker:|r Summon Doomguard cooldown estimate set to " .. tostring(db.doomguardCooldown) .. "s.")
        end
    elseif cmd == "options" or cmd == "config" then
        OpenOptionsPanel()
    else
        print("|cff9d7dffImpTracker:|r Commands: /wit clear | status | options")
        print("|cff9d7dffImpTracker:|r /wit threshold <n> | implodecd <sec> | siphoncd <sec> | doomguardcd <sec>")
    end

    UpdateDisplay()
end

local function HandleImplosionCast(now)
    local removed = RemoveImpCount(IMPS_REMOVED_PER_IMPLOSION, now)
    if removed > 0 and HasToHellAndBack() then
        AddGroup(math.floor(removed / 2), "to-hell-and-back", now)
    end

    nextImplosionReadyAt = now + (db.implosionCooldown or defaults.implosionCooldown)
end

local function HandlePowerSiphonCast(now)
    local removed = RemoveImpCount(IMPS_REMOVED_PER_POWER_SIPHON, now)
    if removed > 0 and HasToHellAndBack() then
        AddGroup(math.floor(removed / 2), "to-hell-and-back", now)
    end

    StartEstimatedTrackedCooldown(POWER_SIPHON_SPELL_ID, now)
end

local function HookCooldownViewer()
    if not EssentialCooldownViewer or EssentialCooldownViewer.ImpTrackerHooked or not EssentialCooldownViewer.GetItemFrames then
        return
    end

    EssentialCooldownViewer.ImpTrackerHooked = true
    hooksecurefunc(EssentialCooldownViewer, "Layout", function()
        wipe(trackedItemFrames)
        CleanupStaleOverlays()
        EnsureAllTrackedOverlays()
        UpdateDisplay()
    end)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event ~= "ADDON_LOADED" and not db then
        EnsureDB()
    end

    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then
            return
        end

        EnsureDB()
        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        EnsureOptionsPanel()
        HookCooldownViewer()
        EnsureAllTrackedOverlays()
        startupGraceUntil = GetTime() + 3
        lastEstimateUpdate = GetTime()
        UpdateDisplay()
        print("|cff9d7dffImpTracker:|r Loaded. Enhancing Blizzard cooldown icons.")
    elseif event == "PLAYER_ENTERING_WORLD" then
        HookCooldownViewer()
        wipe(trackedItemFrames)
        ResetTrackerState(true)
        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        startupGraceUntil = GetTime() + 3
        UpdateDisplay()
    elseif event == "PLAYER_REGEN_DISABLED" then
        lastEstimateUpdate = GetTime()
        UpdateDisplay()
    elseif event == "PLAYER_REGEN_ENABLED" then
        lastEstimateUpdate = GetTime()
        UpdateDisplay()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if unit ~= "player" then
            return
        end

        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        ResetTrackerState(true)
        UpdateDisplay()
    elseif event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        nextInnerDemonAt = nil
        UpdateTyrantWindowState()
        UpdateDisplay()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            UpdateDisplay()
        end
    elseif event == "UNIT_SPELLCAST_START" then
        local unit, castGUID, spellID = ...
        if unit ~= "player" then
            return
        end

        if spellID == HAND_OF_GULDAN_SPELL_ID and castGUID then
            pendingHoG[castGUID] = MAX_HAND_OF_GULDAN_IMPS
        end

        UpdateDisplay()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit ~= "player" then
            return
        end

        local now = GetTime()
        local normalizedSpellID = NormalizeTrackedCastSpellID(spellID)
        local castSpellName = GetSpellNameByID(spellID)
        if castSpellName and (castSpellName == localizedNames.powerSiphon or castSpellName == FALLBACK_NAMES.powerSiphon) then
            RememberName("powerSiphon", castSpellName)
            RememberSpellID("powerSiphon", spellID)
            trackedSpellAliases[spellID] = POWER_SIPHON_SPELL_ID
            normalizedSpellID = POWER_SIPHON_SPELL_ID
        elseif castSpellName and (castSpellName == localizedNames.summonDoomguard or castSpellName == FALLBACK_NAMES.summonDoomguard) then
            RememberName("summonDoomguard", castSpellName)
            normalizedSpellID = EnsureDoomguardTracking(spellID) or normalizedSpellID
        end

        if spellID == HAND_OF_GULDAN_SPELL_ID then
            local count = pendingHoG[castGUID]
            pendingHoG[castGUID] = nil
            AddGroup(count or MAX_HAND_OF_GULDAN_IMPS, "hand-of-guldan", now)
            if IsTyrantWindowActive(now) then
                tyrantHoGCount = (tyrantHoGCount or 0) + 1
            end
        elseif normalizedSpellID == IMPLOSION_SPELL_ID then
            HandleImplosionCast(now)
        elseif normalizedSpellID == POWER_SIPHON_SPELL_ID then
            HandlePowerSiphonCast(now)
        elseif normalizedSpellID == SUMMON_DEMONIC_TYRANT_SPELL_ID then
            StartEstimatedTrackedCooldown(normalizedSpellID, now)
            StartTyrantWindow(now)
        elseif trackedCooldownState[normalizedSpellID] then
            StartEstimatedTrackedCooldown(normalizedSpellID, now)
        end

        UpdateDisplay()
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        local unit, castGUID = ...
        if unit == "player" and castGUID then
            pendingHoG[castGUID] = nil
        end
        UpdateDisplay()
    end
end)

C_Timer.NewTicker(0.20, function()
    UpdateDisplay()
end)
