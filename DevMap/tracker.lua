-- tracker.lua
-- Adds a "Ready For Turn In" section to the All Objectives (objective tracker)
-- UI, listing ready-to-turn-in quests grouped by zone. The zone grouping is
-- shared with the "print ready for turn in" button
-- (DevMap.GetReadyQuestsByZone).
--
-- The tracker is made of modules (one per section: Quests, Campaign, ...).
-- A module is a frame built from ObjectiveTrackerModuleTemplate with a mixin
-- created from ObjectiveTrackerModuleMixin; the manager assigns each module to
-- ObjectiveTrackerFrame and sorts them by uiOrder.
--
-- For now this is scaffolding: header "DevMap" plus one placeholder line.

local DevMap = _G.DevMap

local MODULE_NAME = "DevMapObjectiveTracker"
local MODULE_TITLE = "Ready For Turn In"
local RETRY_ATTEMPTS = 20 -- 20 x 0.5s, covers the tracker addon loading later

local function Log(msg)
    if DevMap and DevMap.Log then
        DevMap:Log(msg)
    else
        print("DevMap: " .. tostring(msg))
    end
end

local function CreateModule()
    local module = CreateFrame("Frame", MODULE_NAME, ObjectiveTrackerFrame,
        "ObjectiveTrackerModuleTemplate")

    module.headerText = MODULE_TITLE
    module.events = {
        "PLAYER_ENTERING_WORLD",
        "ZONE_CHANGED_NEW_AREA",
        "QUEST_LOG_UPDATE",
        "QUEST_WATCH_LIST_CHANGED",
        "QUEST_TURNED_IN",
        "QUEST_ACCEPTED",
        "UNIT_QUEST_LOG_CHANGED",
    }
    module.uiOrder = 100 -- after the built-in modules (they are 1..11)

    function module:InitModule()
        -- no module-level state yet
    end

    function module:OnEvent(event, ...)
        self:MarkDirty()
    end

    function module:LayoutContents()
        local groups = DevMap.GetReadyQuestsByZone and DevMap.GetReadyQuestsByZone() or {}

        if #groups == 0 then
            local block = self:GetBlock("empty")
            block:AddObjective("none", "No quests ready to turn in", nil, nil,
                OBJECTIVE_DASH_STYLE_HIDE, OBJECTIVE_TRACKER_COLOR["Normal"])
            self:LayoutBlock(block)
            return
        end

        -- One block per zone, zone name as the block header.
        for _, group in ipairs(groups) do
            local block = self:GetBlock("zone_" .. tostring(group.key))
            block:SetHeader(group.name)
            for _, quest in ipairs(group.quests) do
                block:AddObjective(quest.id, quest.title, nil, nil,
                    OBJECTIVE_DASH_STYLE_HIDE, OBJECTIVE_TRACKER_COLOR["Normal"])
            end
            if not self:LayoutBlock(block) then
                return
            end
        end
    end

    module:SetHeader(MODULE_TITLE)
    return module
end

local function ManagerIsReady()
    return ObjectiveTrackerManager and ObjectiveTrackerFrame
        and ObjectiveTrackerManager.containers[ObjectiveTrackerFrame]
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

    local module = _G[MODULE_NAME]
    if not module then
        module = CreateModule()
    end

    if not ObjectiveTrackerManager:GetContainerForModule(module) then
        ObjectiveTrackerManager:SetModuleContainer(module, ObjectiveTrackerFrame)
    end
    return true
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
