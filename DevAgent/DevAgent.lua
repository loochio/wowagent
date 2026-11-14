-- DevAgent.lua
-- Basic scaffold addon. Designed to make it obvious (in-game and via SavedVariables)
-- whenever a new build has actually loaded, so an external sync/reload agent has
-- something concrete to verify against.

local ADDON_NAME = ...

-- Bump this string from your build/sync step (e.g. stamp it with a git SHA or
-- timestamp) so you can visually confirm in chat that /reload picked up your
-- latest edit.
local BUILD_VERSION = "dev-0427d1f-dirty"

DevAgentDB = DevAgentDB or {
    errors = {},
    loadHistory = {},
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

local function Log(msg)
    print("|cff33ff99DevAgent:|r " .. tostring(msg))
end

-- Capture Lua errors into SavedVariables so an external tool can tail the
-- WTF SavedVariables file after a /reload and see what broke, without you
-- having to alt-tab into the game.
local function CaptureError(errMsg)
    table.insert(DevAgentDB.errors, {
        time = date("%Y-%m-%d %H:%M:%S"),
        message = tostring(errMsg),
    })
    -- Keep the log from growing forever.
    while #DevAgentDB.errors > 100 do
        table.remove(DevAgentDB.errors, 1)
    end
end

local originalErrorHandler = geterrorhandler()
seterrorhandler(function(errMsg)
    CaptureError(errMsg)
    return originalErrorHandler(errMsg)
end)

frame:SetScript("OnEvent", function(self, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon == ADDON_NAME then
        table.insert(DevAgentDB.loadHistory, {
            time = date("%Y-%m-%d %H:%M:%S"),
            version = BUILD_VERSION,
        })
        while #DevAgentDB.loadHistory > 20 do
            table.remove(DevAgentDB.loadHistory, 1)
        end
    elseif event == "PLAYER_LOGIN" then
        Log("loaded, build " .. BUILD_VERSION)
    end
end)

SLASH_DEVAGENT1 = "/devagent"
SlashCmdList["DEVAGENT"] = function(msg)
    msg = (msg or ""):lower():trim()
    if msg == "errors" then
        if #DevAgentDB.errors == 0 then
            Log("no errors logged.")
        else
            for i = math.max(1, #DevAgentDB.errors - 4), #DevAgentDB.errors do
                local e = DevAgentDB.errors[i]
                Log(e.time .. " - " .. e.message)
            end
        end
    elseif msg == "clear" then
        wipe(DevAgentDB.errors)
        Log("error log cleared.")
    else
        Log("build " .. BUILD_VERSION .. " | commands: /devagent errors, /devagent clear")
    end
end
