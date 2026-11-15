-- DevMap.lua
-- Scaffold addon for editing the world map and quest log UI.
--
-- Nothing is hooked into Blizzard frames except map.lua's search-bar button.
-- This file sets up the load/error plumbing (mirroring DevAgent) plus a module
-- registry, so map and quest log work can be added as self-contained files.

local ADDON_NAME = ...

-- Bumped by the build/sync step so /reload pickup is visible in chat.
local BUILD_VERSION = "dev-da48f2f"

DevMapDB = DevMapDB or {
    errors = {},
    loadHistory = {},
}

-- Public namespace. Real features register themselves as modules:
--   DevMap:AddModule("map", function() ... end)
--   DevMap:AddModule("questlog", function() ... end)
DevMap = DevMap or {
    modules = {},
    order = {},
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

function DevMap:Log(msg)
    print("|cff66ccffDevMap:|r " .. tostring(msg))
end

local function Log(msg)
    DevMap:Log(msg)
end

-- Capture Lua errors into SavedVariables so an external tool can tail the
-- WTF file after a /reload and see what broke without alt-tabbing.
local function CaptureError(errMsg)
    table.insert(DevMapDB.errors, {
        time = date("%Y-%m-%d %H:%M:%S"),
        message = tostring(errMsg),
    })
    while #DevMapDB.errors > 100 do
        table.remove(DevMapDB.errors, 1)
    end
end

local originalErrorHandler = geterrorhandler()
seterrorhandler(function(errMsg)
    CaptureError(errMsg)
    return originalErrorHandler(errMsg)
end)

function DevMap:AddModule(name, init)
    if self.modules[name] then
        Log("module '" .. name .. "' already registered, ignoring.")
        return
    end
    self.modules[name] = init
    table.insert(self.order, name)
end

-- Modules are initialized at PLAYER_LOGIN, each isolated by pcall so one
-- broken module can't take the addon (or the login) down with it.
local function RunModules()
    for _, name in ipairs(DevMap.order) do
        local ok, err = pcall(DevMap.modules[name], DevMap)
        if not ok then
            local message = "module '" .. name .. "' failed: " .. tostring(err)
            CaptureError(message)
            Log(message)
        end
    end
end

frame:SetScript("OnEvent", function(self, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon == ADDON_NAME then
        table.insert(DevMapDB.loadHistory, {
            time = date("%Y-%m-%d %H:%M:%S"),
            version = BUILD_VERSION,
        })
        while #DevMapDB.loadHistory > 20 do
            table.remove(DevMapDB.loadHistory, 1)
        end
    elseif event == "PLAYER_LOGIN" then
        RunModules()
        Log(("loaded, build %s (%d module(s))"):format(BUILD_VERSION, #DevMap.order))
    end
end)

SLASH_DEVMAP1 = "/devmap"
SlashCmdList["DEVMAP"] = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "errors" then
        if #DevMapDB.errors == 0 then
            Log("no errors logged.")
        else
            for i = math.max(1, #DevMapDB.errors - 4), #DevMapDB.errors do
                local e = DevMapDB.errors[i]
                Log(e.time .. " - " .. e.message)
            end
        end
    elseif msg == "clear" then
        wipe(DevMapDB.errors)
        Log("error log cleared.")
    elseif msg == "modules" then
        if #DevMap.order == 0 then
            Log("no modules registered yet.")
        else
            Log("modules: " .. table.concat(DevMap.order, ", "))
        end
    elseif msg == "quests" then
        if DevMap.DumpQuestZones then
            DevMap:DumpQuestZones()
        else
            Log("map module not loaded.")
        end
    elseif msg == "tracker" then
        if DevMap.TryEnsureTracker then
            DevMap.TryEnsureTracker()
            Log("tracker module re-registered.")
        else
            Log("tracker module not loaded.")
        end
    else
        Log("build " .. BUILD_VERSION
            .. " | commands: /devmap errors, /devmap clear, /devmap modules, /devmap quests, /devmap tracker")
    end
end
