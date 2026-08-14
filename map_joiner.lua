-- ============================================================================
-- PROJECT SLAYERS - MAP JOINER  (standalone, one-shot)
-- Executor Lua (Roblox), single file. Pick a MAP and (optionally) a private CODE;
-- it takes you there. Same remotes/place ids as the hub.
--
-- HOW IT ROUTES:
--   * No code  -> straight TeleportService teleport to the chosen place.
--   * With code-> the private-join remote only works from the LOBBY, so if you're
--                 not there it hops to the Lobby first, then redeems the code. A
--                 marker file makes it fire the join exactly ONCE (no teleport loop).
--
-- CROSS-TELEPORT: the lobby-hop needs the script to re-run after the teleport, so
--   host THIS file at a raw URL and set LOADER_URL (same as the mugen loop). If you
--   ALWAYS start from the Lobby, LOADER_URL can stay empty.
-- ============================================================================

--========================= CONFIG - EDIT THESE ==============================
local TARGET_MAP   = "Map 2"   -- name below, OR a raw place id number. Where you want to go.
local PRIVATE_CODE = ""        -- private server code. "" = public/random teleport (no code).
local LOADER_URL   = ""        -- raw github link to THIS file (needed only for the code+lobby-hop)
local JUMP_ANTIAFK = false     -- also jump every 60s (resets game-side AFK detection)
--============================================================================

-- Friendly names -> place ids. For a CODE join, the id is the PUBLIC place the code
-- resolves an instance of (Map 1 / Map 2). Add your own rows freely.
local MAPS = {
    ["lobby"]         = 5956785391,
    ["hub"]           = 9321822839,
    ["map 1"]         = 17387475546,
    ["map 2"]         = 17387482786,
    ["map 2 private"] = 13883059853,   -- dedicated random-private Map 2 (no code)
    ["ouwigahara"]    = 11468075017,   -- Ouwigahara dungeon
    ["mugen"]         = 11468034852,   -- Mugen Train place
}

repeat task.wait() until game:IsLoaded()

-- SERVICES
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local VirtualUser       = game:GetService("VirtualUser")

local client  = Players.LocalPlayer
local placeId = game.PlaceId
local LOBBY   = 5956785391
local MARKER  = "FireHub/PJS/mapjoin_pending"

-- Resolve TARGET_MAP (name or raw id) to a numeric place id
local targetId
if type(TARGET_MAP) == "number" then
    targetId = TARGET_MAP
elseif tonumber(TARGET_MAP) then
    targetId = tonumber(TARGET_MAP)
else
    targetId = MAPS[tostring(TARGET_MAP):lower()]
end
if not targetId then
    warn("[MapJoiner] unknown TARGET_MAP '" .. tostring(TARGET_MAP) .. "'. Use a name from MAPS or a raw place id.")
    return
end

--========================= ANTI-AFK (hardened) ==============================
-- Re-armed every execution (a teleport kills the old Idled connection). Idled reset
-- works tabbed-out; the 60s heartbeat feeds input before the timer nears the kick.
do
    local function resetIdle()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
    client.Idled:Connect(resetIdle)
    task.spawn(function()
        while task.wait(60) do
            resetIdle()
            if JUMP_ANTIAFK then
                pcall(function()
                    local hum = client.Character and client.Character:FindFirstChildOfClass("Humanoid")
                    if hum then hum.Jump = true end
                end)
            end
        end
    end)
end

--===================== TELEPORT PERSISTENCE (queue) =========================
local function queuePersist()
    if LOADER_URL == "" then return end
    local q = (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)
        or queue_on_teleport
        or queueonteleport
    if q then pcall(q, ("loadstring(game:HttpGet(%q))()"):format(LOADER_URL)) end
end

--=============================== HELPERS ====================================
local function clearMarker() pcall(function() if isfile(MARKER) then delfile(MARKER) end end) end
local function setMarker()   pcall(function() writefile(MARKER, tostring(targetId)) end) end
local function markerSet()   local ok, v = pcall(isfile, MARKER); return ok and v end

--=============================== DRIVER =====================================
queuePersist()

task.spawn(function()
    task.wait(1)

    -- NO CODE: direct teleport. If we're already at the target, we're done.
    if PRIVATE_CODE == "" then
        if placeId ~= targetId then
            TeleportService:Teleport(targetId, client)
        else
            warn("[MapJoiner] already at target place " .. targetId .. " - nothing to do.")
        end
        return
    end

    -- WITH CODE: must redeem from the Lobby.
    if placeId == LOBBY then
        setMarker()   -- claim: so the re-exec after landing doesn't hop again
        ReplicatedStorage:WaitForChild("handle_privateserver", math.huge):InvokeServer("join", PRIVATE_CODE, targetId)
        warn("[MapJoiner] redeeming code '" .. PRIVATE_CODE .. "' -> place " .. targetId)
    elseif markerSet() then
        -- we already redeemed and this is the arrival re-exec -> finished
        clearMarker()
        warn("[MapJoiner] arrived via code. done.")
    else
        -- not in the lobby yet and haven't redeemed -> go to the Lobby to use the remote
        warn("[MapJoiner] hopping to Lobby to redeem the code...")
        TeleportService:Teleport(LOBBY, client)
    end
end)
