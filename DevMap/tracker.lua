-- tracker.lua
-- Adds sections to the All Objectives (objective tracker) UI:
--   "Ready For Turn In" -> ready-to-turn-in quests grouped by zone
--   "Quest Count"       -> quests in log / max quests
--
-- The tracker is made of modules (one per section: Quests, Campaign, ...).
-- A module is a frame built from ObjectiveTrackerModuleTemplate; the manager
-- assigns each module to ObjectiveTrackerFrame and sorts them by uiOrder.

local DevMap = _G.DevMap

local RETRY_ATTEMPTS = 20 -- 20 x 0.5s, covers the tracker addon loading later

local function Log(msg)
    if DevMap and DevMap.Log then
        DevMap:Log(msg)
    else
        print("DevMap: " .. tostring(msg))
    end
end

-- Both sections refresh on quest log changes.
local MODULE_EVENTS = {
    "PLAYER_ENTERING_WORLD",
    "ZONE_CHANGED_NEW_AREA",
    "QUEST_LOG_UPDATE",
    "QUEST_WATCH_LIST_CHANGED",
    "QUEST_TURNED_IN",
    "QUEST_ACCEPTED",
    "UNIT_QUEST_LOG_CHANGED",
}

-- Make a quest line clickable: opens that quest in the quest log.
local function AttachQuestClick(line, questID)
    local button = line.devMapClickButton
    if not button then
        button = CreateFrame("Button", nil, line)
        button:SetAllPoints(line)

        button:SetScript("OnClick", function(self)
            local questID = self.devMapQuestID
            if questID and QuestMapFrame_OpenToQuestDetails then
                QuestMapFrame_OpenToQuestDetails(questID)
            end
        end)

        button:SetScript("OnEnter", function(self)
            local text = self:GetParent().Text
            if text then
                text:SetTextColor(HIGHLIGHT_FONT_COLOR:GetRGB())
            end
        end)

        button:SetScript("OnLeave", function(self)
            local text = self:GetParent().Text
            local color = OBJECTIVE_TRACKER_COLOR["Normal"]
            if text and color then
                text:SetTextColor(color.r, color.g, color.b)
            end
        end)

        line.devMapClickButton = button
    end

    button.devMapQuestID = questID
    button:Show()
end

local function LayoutReadyForTurnIn(module)
    local groups = DevMap.GetReadyQuestsByZone and DevMap.GetReadyQuestsByZone() or {}

    if #groups == 0 then
        local block = module:GetBlock("empty")
        block:AddObjective("none", "No quests ready to turn in", nil, nil,
            OBJECTIVE_DASH_STYLE_HIDE, OBJECTIVE_TRACKER_COLOR["Normal"])
        module:LayoutBlock(block)
        return
    end

    -- One block per zone, zone name as the block header.
    for _, group in ipairs(groups) do
        local block = module:GetBlock("zone_" .. tostring(group.key))
        block:SetHeader(group.name)
        for _, quest in ipairs(group.quests) do
            local line = block:AddObjective(quest.id, quest.title, nil, nil,
                OBJECTIVE_DASH_STYLE_HIDE, OBJECTIVE_TRACKER_COLOR["Normal"])
            AttachQuestClick(line, quest.id)
        end
        if not module:LayoutBlock(block) then
            return
        end
    end
end

local function LayoutQuestCount(module)
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then
        return
    end

    -- The quest log's own counter shows the second return and the accept cap.
    local _, numQuests = C_QuestLog.GetNumQuestLogEntries()
    local maxQuests = Constants and Constants.QuestLogConsts
        and Constants.QuestLogConsts.MAXIMUM_NUM_QUESTS_LOG_CAN_ACCEPT
        or C_QuestLog.GetMaxNumQuests()

    local block = module:GetBlock("count")
    block:AddObjective("count", ("%d / %d"):format(numQuests or 0, maxQuests or 0),
        nil, nil, OBJECTIVE_DASH_STYLE_HIDE, OBJECTIVE_TRACKER_COLOR["Normal"])
    module:LayoutBlock(block)
end

local MODULES = {
    {
        key = "ready",
        name = "DevMapObjectiveTracker",
        title = "Ready For Turn In",
        uiOrder = 100,
        layout = LayoutReadyForTurnIn,
    },
    {
        key = "count",
        name = "DevMapQuestCountTracker",
        title = "Quest Count",
        uiOrder = 101,
        layout = LayoutQuestCount,
    },
}

local SETTING_KEYS = {
    ready = "showReadySection",
    count = "showQuestCount",
}

local function ModuleEnabled(key)
    local setting = SETTING_KEYS[key]
    if not setting or not DevMapDB then
        return true -- sections are on unless explicitly switched off
    end
    return DevMapDB[setting] ~= false
end

local function CreateModule(def)
    local module = CreateFrame("Frame", def.name, ObjectiveTrackerFrame,
        "ObjectiveTrackerModuleTemplate")

    module.headerText = def.title
    module.events = MODULE_EVENTS
    module.uiOrder = def.uiOrder

    function module:LayoutContents()
        -- A suppressed module lays out nothing, so the tracker hides it
        -- without us having to add/remove it from the container.
        if self.suppressed then
            return
        end
        def.layout(self)
    end

    module:SetHeader(def.title)
    return module
end

local function EnsureModule()
    if not (ObjectiveTrackerFrame and ObjectiveTrackerManager) then
        return false
    end

    -- ObjectiveTrackerManager:Init runs after PLAYER_ENTERING_WORLD /
    -- VARIABLES_LOADED and is what registers the container.
    if not ObjectiveTrackerManager.containers[ObjectiveTrackerFrame] then
        return false
    end

    for _, def in ipairs(MODULES) do
        local module = _G[def.name]
        if not module then
            module = CreateModule(def)
        end

        -- A disabled section is suppressed (lays out nothing) but stays
        -- registered, so toggling never disturbs the other sections.
        local suppressed = (not ModuleEnabled(def.key)) or nil
        if module.suppressed ~= suppressed then
            module.suppressed = suppressed
            module:MarkDirty()
        end

        if not ObjectiveTrackerFrame:HasModule(module) then
            ObjectiveTrackerManager:SetModuleContainer(module, ObjectiveTrackerFrame)
        end
    end
    return true
end

-- Called by the checkboxes in the quest log. Persists across sessions.
local function SetModuleShown(key, shown)
    DevMapDB = DevMapDB or {}
    local setting = SETTING_KEYS[key]
    if setting then
        DevMapDB[setting] = shown and true or false
    end

    local def = nil
    for _, moduleDef in ipairs(MODULES) do
        if moduleDef.key == key then
            def = moduleDef
            break
        end
    end
    if not def then
        return
    end

    local module = _G[def.name]
    if not module then
        if shown and ObjectiveTrackerFrame and ObjectiveTrackerManager then
            module = CreateModule(def)
            ObjectiveTrackerManager:SetModuleContainer(module, ObjectiveTrackerFrame)
        end
        return
    end

    if shown then
        module.suppressed = nil
    else
        module.suppressed = true
    end
    module:MarkDirty()
    if not shown then
        module:Hide()
    end
end

function DevMap:SetReadySectionShown(shown)
    SetModuleShown("ready", shown)
end

function DevMap:SetQuestCountShown(shown)
    SetModuleShown("count", shown)
end

local retrying = false

local function TryEnsure(attempt)
    if EnsureModule() then
        retrying = false
        return
    end
    if retrying or (attempt or 0) >= RETRY_ATTEMPTS then
        return
    end
    retrying = true
    C_Timer.After(0.5, function()
        retrying = false
        TryEnsure((attempt or 0) + 1)
    end)
end

DevMap.TryEnsureTracker = TryEnsure

-- The tracker addon is loaded normally, but retry in case it loads on demand.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function(self, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon ~= "Blizzard_ObjectiveTracker" then
        return
    end
    TryEnsure()
end)

DevMap:AddModule("tracker", function()
    TryEnsure()
end)
