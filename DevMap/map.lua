-- map.lua
-- World map / quest log UI additions.
--
-- Adds two buttons at the bottom of the "Map & Quest Log" panel:
--   "clear tracking"     -> removes every tracked quest
--   "Track Current Zone" -> clears tracking, then tracks quests whose
--                           zone matches the zone the player is in
-- Plus two checkboxes that toggle the matching objective tracker sections:
--   "Track - Ready for Turn In" and "Track - Quest Count"
-- The search box lives at QuestScrollFrame.SearchBox in
-- Blizzard_UIPanels_Game, which may load on demand, so setup is retried until
-- it exists.

local DevMap = _G.DevMap

local BUTTON_MIN_WIDTH = 90
local BUTTON_HEIGHT = 20
local BUTTON_GAP = 4 -- vertical gap between the checkbox and the buttons
local BUTTON_SPACING = 6 -- between the two buttons
local BOTTOM_INSET = 6 -- padding from the panel's bottom-left corner
local CHECKBOX_HEIGHT = 32 -- UICheckButtonTemplate is 32x32
local CHECKBOX_SPACING = 8 -- between the two checkboxes

local CLEAR_BUTTON = "DevMapClearTrackingButton"
local TRACK_BUTTON = "DevMapTrackZoneButton"
local READY_CHECKBOX = "DevMapReadyCheckbox"
local COUNT_CHECKBOX = "DevMapQuestCountCheckbox"
local PANEL_BACKGROUND = "DevMapPanelBackground"
local MINIMIZE_BUTTON = "DevMapMinimizeButton"
local MAXIMIZE_BUTTON = "DevMapMaximizeButton"

-- First hit wins. The first entry is the current live layout; the others are
-- cheap fallbacks in case this client's quest log is built differently.
local SEARCHBOX_CANDIDATES = {
    function() return _G.QuestScrollFrame and _G.QuestScrollFrame.SearchBox end,
    function() return _G.QuestLogFrame and _G.QuestLogFrame.SearchBox end,
    function() return _G.QuestLogSearchBox end,
}

local function Log(msg)
    if DevMap and DevMap.Log then
        DevMap:Log(msg)
    else
        print("DevMap: " .. tostring(msg))
    end
end

local function GetSearchBox()
    for _, resolve in ipairs(SEARCHBOX_CANDIDATES) do
        local searchBox = resolve()
        if searchBox then
            return searchBox
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Tracking
-- ---------------------------------------------------------------------------

local function IsQuestWatched(questID)
    return questID and C_QuestLog.GetQuestWatchType(questID) ~= nil
end

local function IsReadyForTurnIn(questID)
    return C_QuestLog.ReadyForTurnIn(questID) == true
end

-- Untrack via the quest log itself (the way Blizzard's own "untrack all" does),
-- then sweep any watch the log scan could not see (hidden entries, etc.).
local function ClearTrackedQuests()
    if not C_QuestLog or not C_QuestLog.GetNumQuestLogEntries then
        return nil
    end

    local cleared = 0
    local function untrack(questID, remove)
        if IsQuestWatched(questID) then
            remove(questID)
            if not IsQuestWatched(questID) then
                cleared = cleared + 1
            end
        end
    end

    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID then
            untrack(info.questID, C_QuestLog.RemoveQuestWatch)
        end
    end

    -- Anything still in the watch list (e.g. hidden log entries).
    if C_QuestLog.GetNumQuestWatches and C_QuestLog.GetQuestIDForQuestWatchIndex then
        for index = C_QuestLog.GetNumQuestWatches(), 1, -1 do
            local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(index)
            if questID then
                untrack(questID, C_QuestLog.RemoveQuestWatch)
            end
        end
    end

    -- World quests are tracked separately and are not in the quest log.
    if C_QuestLog.GetNumWorldQuestWatches
        and C_QuestLog.GetQuestIDForWorldQuestWatchIndex
        and C_QuestLog.RemoveWorldQuestWatch then
        for index = C_QuestLog.GetNumWorldQuestWatches(), 1, -1 do
            local questID = C_QuestLog.GetQuestIDForWorldQuestWatchIndex(index)
            if questID then
                untrack(questID, C_QuestLog.RemoveWorldQuestWatch)
            end
        end
    end

    return cleared
end

local function CountTrackedQuests()
    local count = 0
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and IsQuestWatched(info.questID) then
            count = count + 1
        end
    end
    if C_QuestLog.GetNumWorldQuestWatches then
        count = count + C_QuestLog.GetNumWorldQuestWatches()
    end
    return count
end

-- Walk a map and its parents until we hit a zone-level map (cities are zones
-- too). Returns nil when the chain has no zone, e.g. a continent map.
local function GetZoneMapID(mapID)
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone
    if not zoneType or not mapID or mapID == 0 then
        return nil
    end

    local guard = 0
    while mapID and mapID ~= 0 and guard < 20 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then
            return nil
        end
        if info.mapType == zoneType then
            return mapID
        end
        mapID = info.parentMapID
        guard = guard + 1
    end
    return nil
end

-- Blizzard's own "active quests for this map" filter (WorldMapBountyBoard):
-- GetQuestsOnMap also returns quests from surrounding maps that are viewable
-- here, so it has to be combined with GetQuestUiMapID(questID) == zoneMapID.
local function BuildQuestsOnMapSet(mapIDs)
    if not (C_QuestLog and C_QuestLog.GetQuestsOnMap) then
        return nil
    end

    local ids = {}
    local scanned = {}
    for _, mapID in ipairs(mapIDs) do
        if mapID and mapID ~= 0 and not scanned[mapID] then
            scanned[mapID] = true
            local pois = C_QuestLog.GetQuestsOnMap(mapID)
            for _, poi in ipairs(pois or {}) do
                if poi.questID then
                    ids[poi.questID] = true
                end
            end
        end
    end
    return ids
end

local function QuestBelongsToZone(questID, zoneMapID, questsOnZone)
    local questMapID = GetQuestUiMapID(questID)
    if not questMapID or questMapID == 0 or questMapID ~= zoneMapID then
        return false
    end
    if questsOnZone then
        return questsOnZone[questID] == true
    end
    return true
end

-- Clears all tracking, then watches every quest log entry whose map belongs
-- to the player's current zone. Returns tracked, zoneName, matchCount, cleared.
local function TrackQuestsInCurrentZone()
    if not C_QuestLog or not C_QuestLog.GetNumQuestLogEntries
        or not GetQuestUiMapID or not C_Map then
        return nil, "quest/map API unavailable."
    end

    local currentMapID = C_Map.GetBestMapForUnit("player")
    local zoneMapID = currentMapID and GetZoneMapID(currentMapID)
    if not zoneMapID then
        return nil, "couldn't determine your current zone."
    end

    local zoneInfo = C_Map.GetMapInfo(zoneMapID)
    local zoneName = (zoneInfo and zoneInfo.name) or "your zone"

    local cleared = ClearTrackedQuests() or 0

    local questsOnZone = BuildQuestsOnMapSet({ zoneMapID, currentMapID })
    local candidates = {}
    local seen = {}
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID and not seen[info.questID] then
            seen[info.questID] = true
            if QuestBelongsToZone(info.questID, zoneMapID, questsOnZone) then
                table.insert(candidates, info.questID)
            end
        end
    end

    local maxWatches = Constants and Constants.QuestWatchConsts
        and Constants.QuestWatchConsts.MAX_QUEST_WATCHES
    local tracked = 0
    for _, questID in ipairs(candidates) do
        if maxWatches and tracked >= maxWatches then
            break
        end
        C_QuestLog.AddQuestWatch(questID)
        if IsQuestWatched(questID) then
            tracked = tracked + 1
        end
    end

    return tracked, zoneName, #candidates, cleared
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- /devmap quests: show how each quest log entry is classified.
function DevMap:DumpQuestZones()
    if not (C_QuestLog and C_Map and GetQuestUiMapID) then
        Log("quest/map API unavailable.")
        return
    end

    local currentMapID = C_Map.GetBestMapForUnit("player")
    local zoneMapID = currentMapID and GetZoneMapID(currentMapID)
    local zoneInfo = zoneMapID and C_Map.GetMapInfo(zoneMapID)
    local questsOnZone = BuildQuestsOnMapSet({ zoneMapID, currentMapID })
    Log(("zone %s (%s), questsOnZone=%s"):format(
        (zoneInfo and zoneInfo.name) or "?",
        tostring(zoneMapID),
        questsOnZone and "yes" or "unavailable"))

    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID then
            local questMapID = GetQuestUiMapID(info.questID)
            local mapInfo = questMapID and C_Map.GetMapInfo(questMapID)
            Log(("%s | map %s %s | zone %s | belongs %s | ready %s | watched %s"):format(
                C_QuestLog.GetTitleForQuestID(info.questID) or "?",
                tostring(questMapID),
                (mapInfo and mapInfo.name) or "?",
                tostring(questMapID and GetZoneMapID(questMapID)),
                tostring(QuestBelongsToZone(info.questID, zoneMapID, questsOnZone)),
                tostring(IsReadyForTurnIn(info.questID)),
                tostring(IsQuestWatched(info.questID))))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Click handlers
-- ---------------------------------------------------------------------------

local function GetQuestZone(questID)
    if not (GetQuestUiMapID and C_Map) then
        return nil, "unknown zone"
    end
    local mapID = GetQuestUiMapID(questID)
    local zoneMapID = mapID and GetZoneMapID(mapID)
    local info = zoneMapID and C_Map.GetMapInfo(zoneMapID)
    return zoneMapID, (info and info.name) or "unknown zone"
end

-- Ready-to-hand-in quests in the log, grouped by the zone their UI map
-- resolves to. Returns groups sorted by zone name, each with its quests
-- sorted by title: { key, name, quests = { { id, title } } }.
local function GetReadyQuestsByZone()
    local groupsByKey = {}
    local groups = {}
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID
            and IsReadyForTurnIn(info.questID) then
            local zoneID, zoneName = GetQuestZone(info.questID)
            local key = zoneID or zoneName
            local group = groupsByKey[key]
            if not group then
                group = { key = key, name = zoneName, quests = {} }
                groupsByKey[key] = group
                groups[#groups + 1] = group
            end
            group.quests[#group.quests + 1] = {
                id = info.questID,
                title = C_QuestLog.GetTitleForQuestID(info.questID) or ("quest " .. info.questID),
            }
        end
    end

    table.sort(groups, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    for _, group in ipairs(groups) do
        table.sort(group.quests, function(a, b)
            return a.title:lower() < b.title:lower()
        end)
    end
    return groups
end

-- Shared with the objective tracker module.
DevMap.GetReadyQuestsByZone = GetReadyQuestsByZone

local function OnClearTracking()
    local cleared = ClearTrackedQuests()
    if cleared == nil then
        DevMap:Log("quest watch API unavailable; nothing was cleared.")
        return
    end

    local remaining = CountTrackedQuests()
    if remaining > 0 then
        DevMap:Log(("cleared %d tracked quest(s); %d still tracked.")
            :format(cleared, remaining))
    else
        DevMap:Log(("cleared %d tracked quest(s)."):format(cleared))
    end
end

local function OnTrackCurrentZone()
    local tracked, zoneOrError, matches, cleared = TrackQuestsInCurrentZone()
    if tracked == nil then
        DevMap:Log(zoneOrError)
        return
    end

    cleared = cleared or 0
    if tracked == 0 then
        DevMap:Log(("cleared %d; no quests for %s in your quest log.")
            :format(cleared, zoneOrError))
    elseif matches and tracked < matches then
        DevMap:Log(("cleared %d; tracked %d of %d quest(s) for %s (watch limit).")
            :format(cleared, tracked, matches, zoneOrError))
    else
        DevMap:Log(("cleared %d; tracked %d quest(s) for %s.")
            :format(cleared, tracked, zoneOrError))
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function CreateButton(name, text, parent)
    local existing = _G[name]
    if existing then
        return existing
    end

    local ok, button = pcall(CreateFrame, "Button", name, parent, "UIPanelButtonTemplate")
    if not ok or not button then
        Log("could not create button: " .. tostring(button))
        return nil
    end

    button:SetSize(BUTTON_MIN_WIDTH, BUTTON_HEIGHT)
    button:SetText(text)

    -- Widen to fit the label (with a little padding) if it needs more room.
    local label = button:GetFontString()
    if label then
        button:SetWidth(math.max(BUTTON_MIN_WIDTH, label:GetStringWidth() + 24))
    end

    return button
end

local function CreateBackground(parent)
    local existing = _G[PANEL_BACKGROUND]
    if existing then
        return existing
    end

    local ok, background = pcall(CreateFrame, "Frame", PANEL_BACKGROUND, parent,
        "BackdropTemplate")
    if not ok or not background then
        Log("could not create background: " .. tostring(background))
        return nil
    end

    background:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    background:SetBackdropColor(0, 0, 0, 1)
    background:SetBackdropBorderColor(0.35, 0.35, 0.35, 0.8)

    return background
end

local function CreateToggleButton(name, text, parent)
    local existing = _G[name]
    if existing then
        return existing
    end

    local ok, button = pcall(CreateFrame, "Button", name, parent, "UIPanelButtonTemplate")
    if not ok or not button then
        Log("could not create button: " .. tostring(button))
        return nil
    end

    button:SetSize(22, 20)
    button:SetText(text)

    return button
end

local function CreateCheckbox(name, label, parent, isChecked, onToggle)
    local existing = _G[name]
    if existing then
        return existing
    end

    local ok, checkbox = pcall(CreateFrame, "CheckButton", name, parent,
        "UICheckButtonTemplate")
    if not ok or not checkbox then
        Log("could not create checkbox: " .. tostring(checkbox))
        return nil
    end

    checkbox.Text:SetText(label)
    checkbox:SetChecked(isChecked())
    checkbox:SetScript("OnClick", function(self)
        onToggle(self:GetChecked())
    end)

    return checkbox
end

local function Setup()
    local searchBox = GetSearchBox()
    if not searchBox then
        return false
    end

    local parent = searchBox:GetParent()
    local background = CreateBackground(parent)
    local clearButton = CreateButton(CLEAR_BUTTON, "Clear Tracking", parent)
    local trackButton = CreateButton(TRACK_BUTTON, "Track Current Zone", parent)
    local readyCheckbox = CreateCheckbox(READY_CHECKBOX, "Track - Ready for Turn In", parent,
        function() return DevMapDB and DevMapDB.showReadySection ~= false end,
        function(checked)
            if DevMap.SetReadySectionShown then
                DevMap:SetReadySectionShown(checked)
            end
        end)
    local countCheckbox = CreateCheckbox(COUNT_CHECKBOX, "Track - Quest Count", parent,
        function() return DevMapDB and DevMapDB.showQuestCount ~= false end,
        function(checked)
            if DevMap.SetQuestCountShown then
                DevMap:SetQuestCountShown(checked)
            end
        end)
    local minimizeButton = CreateToggleButton(MINIMIZE_BUTTON, "_", parent)
    local maximizeButton = CreateToggleButton(MAXIMIZE_BUTTON, "+", parent)
    if not background or not clearButton or not trackButton
        or not readyCheckbox or not countCheckbox
        or not minimizeButton or not maximizeButton then
        return false
    end

    -- Checkboxes stacked in a column, buttons above them.
    local checkboxStackHeight = CHECKBOX_HEIGHT * 2 + CHECKBOX_SPACING
    countCheckbox:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", BOTTOM_INSET, BOTTOM_INSET)
    readyCheckbox:SetPoint("BOTTOMLEFT", countCheckbox, "TOPLEFT", 0, CHECKBOX_SPACING)
    clearButton:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", BOTTOM_INSET,
        BOTTOM_INSET + checkboxStackHeight + BUTTON_GAP)
    trackButton:SetPoint("BOTTOMLEFT", clearButton, "BOTTOMRIGHT", BUTTON_SPACING, 0)

    -- Solid panel behind all elements: left/top padded, right and
    -- bottom flush with the parent's edges.
    background:SetPoint("TOPLEFT", clearButton, "TOPLEFT", -4, 6)
    background:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    local frameLevel = searchBox:GetFrameLevel() + 5
    clearButton:SetFrameLevel(frameLevel)
    trackButton:SetFrameLevel(frameLevel)
    readyCheckbox:SetFrameLevel(frameLevel)
    countCheckbox:SetFrameLevel(frameLevel)
    minimizeButton:SetFrameLevel(frameLevel)
    maximizeButton:SetFrameLevel(frameLevel)
    background:SetFrameLevel(searchBox:GetFrameLevel())

    -- Minimize/maximize the whole DevMap block.
    local panelElements = {
        background, clearButton, trackButton, readyCheckbox, countCheckbox,
    }

    local function applyMinimized(minimized)
        for _, frame in ipairs(panelElements) do
            frame:SetShown(not minimized)
        end
        minimizeButton:SetShown(not minimized)
        maximizeButton:SetShown(minimized)
    end

    -- Both toggles live in the bottom-right corner of the quest log panel.
    minimizeButton:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 8)
    maximizeButton:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 8)

    minimizeButton:SetScript("OnClick", function()
        DevMapDB = DevMapDB or {}
        DevMapDB.devMapMinimized = true
        applyMinimized(true)
    end)

    maximizeButton:SetScript("OnClick", function()
        DevMapDB = DevMapDB or {}
        DevMapDB.devMapMinimized = false
        applyMinimized(false)
    end)

    applyMinimized(DevMapDB and DevMapDB.devMapMinimized or false)

    clearButton:SetScript("OnClick", OnClearTracking)
    trackButton:SetScript("OnClick", OnTrackCurrentZone)

    return true
end

-- Retry when the Blizzard addon that owns the quest log finishes loading.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", function(self, event, loadedAddon)
    if Setup() then
        self:UnregisterAllEvents()
    elseif loadedAddon == "Blizzard_UIPanels_Game" then
        Log("quest log search box not found; the DevMap buttons were not created.")
    end
end)

DevMap:AddModule("map", function()
    if Setup() then
        watcher:UnregisterAllEvents()
    else
        Log("waiting for the quest log UI to load...")
    end
end)
