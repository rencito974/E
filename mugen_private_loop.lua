-- ============================================================================
-- PROJECT SLAYERS - MUGEN PRIVATE-SERVER LOOP  (standalone)
-- Executor Lua (Roblox), single file. Uses the same remotes/place ids as the hub.
--
-- WHAT IT DOES (a place-driven state machine, re-runs itself on every teleport):
--   Lobby   -> join your PRIVATE Map 2 (by code, or a random low-pop private)
--   Map 2   -> wait for the train window (min 0-10 of the hour), buy a ticket if
--              needed, then board the teleporter SLOT you picked (1-10)
--   Mugen   -> ride the run; leave when it ends (Cutscene10) or after a failsafe
--              timeout, teleport back to the Lobby -> the loop repeats forever
--
-- COMBAT IS NOT THIS SCRIPT'S JOB. Run your own killaura (or the hub's Full Auto
--   Solo Mugen) alongside it for damage; this script OWNS navigation only. If you
--   just want to board + leave on a timer, set FORCE_LEAVE_AFTER below.
--
-- CROSS-TELEPORT PERSISTENCE: Roblox kills scripts on teleport. To keep looping,
--   host THIS file at a raw URL and put it in LOADER_URL. Empty = one hop only,
--   no repeat (it can't re-inject itself after the teleport).
-- ============================================================================

--========================= CONFIG - EDIT THESE ==============================
local PRIVATE_CODE      = "6RgvfNL9"      -- Map 2 private server code. "" = random low-pop private.
local TELEPORTER_SLOT   = 1       -- which Mugen train teleporter to board (1-10, clamped to what exists)
local FORCE_LEAVE_AFTER = 0       -- secs after boarding to force-leave regardless of run state. 0 = wait for the run to end.
local MAX_RUN_SECONDS   = 720     -- hard cap in the Mugen place before bailing out (never hang forever)
local JUMP_ANTIAFK      = true   -- also jump every 60s (resets game-side AFK detection; may nudge you mid-run)
local LEADER_NAME       = "artu2" -- alts only board the train while THIS player is in their server. "" = no gate.
local LEADER_STABLE_SECS= 5       -- artu2 must be LOADED (character in) & present this long before alts commit
local BOARD_DELAY       = 5       -- settle after the gate passes, so the run finishes generating before we board
local BOARD_JITTER      = 3       -- + up to this many random secs per account, so alts don't pile onto one frame
local TWEEN_SPEED       = 250     -- studs/sec for the walk onto the teleporter (higher = snappier)
local LOADER_URL        = "https://raw.githubusercontent.com/rencito974/E/refs/heads/main/mugen_private_loop.lua"      -- YOUR raw github link to THIS file, e.g. "https://raw.githubusercontent.com/you/repo/main/mugen_private_loop.lua"
--============================================================================

repeat task.wait() until game:IsLoaded()

-- SERVICES
local Players          = game:GetService("Players")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local TeleportService  = game:GetService("TeleportService")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local VirtualUser      = game:GetService("VirtualUser")

local client  = Players.LocalPlayer
local placeId = game.PlaceId

-- PLACE IDS (verified against the hub source)
local LOBBY        = 5956785391
local HUB          = 9321822839
local MAP2_PUBLIC  = 17387482786   -- private-code joins land in an instance of this place
local MAP2_PRIVATE = 13883059853   -- dedicated random-private Map 2 place
local MUGEN        = 11468034852   -- Mugen Train place

local function inLobby() return placeId == LOBBY end
local function inMap2()  return placeId == MAP2_PUBLIC or placeId == MAP2_PRIVATE end
local function inMugen() return placeId == MUGEN end

--========================= ANTI-AFK (hardened) ==============================
-- Re-armed on EVERY execution. A teleport lands in a fresh DataModel, so the old
-- Idled connection is DEAD - a getgenv guard would leave every place after the
-- lobby with no anti-afk, which is exactly how you get idle-kicked mid-loop.
-- Duplicate connections in one place are harmless (they just double-reset).
--   1) client.Idled  -> reset the instant Roblox's 20-min timer trips (works tabbed out)
--   2) 60s heartbeat -> proactively feed input so the timer never nears the kick
--   3) optional jump -> resets the GAME's own movement-based AFK check (JUMP_ANTIAFK)
do
    local function resetIdle()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())          -- simulated input == idle timer reset
        end)
    end

    client.Idled:Connect(resetIdle)

    task.spawn(function()
        while task.wait(60) do
            resetIdle()
            if JUMP_ANTIAFK then                             -- server-side "are you moving" reset
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
    if LOADER_URL == "" then
        warn("[MugenLoop] LOADER_URL is empty - the loop will do ONE teleport hop, then stop. Host this file and set LOADER_URL to keep it repeating.")
        return
    end
    local q = (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)
        or queue_on_teleport
        or queueonteleport
    if q then
        pcall(q, ("loadstring(game:HttpGet(%q))()"):format(LOADER_URL))
    else
        warn("[MugenLoop] executor has no queue_on_teleport - cross-teleport looping unavailable.")
    end
end

--============================ MOVEMENT HELPERS ==============================
local _tween
local function tweento(cf)
    local char = client.Character or client.CharacterAdded:Wait()
    local hrp  = char:WaitForChild("HumanoidRootPart")
    local dist = (cf.Position - hrp.Position).Magnitude
    local t = TweenService:Create(hrp, TweenInfo.new(dist / TWEEN_SPEED, Enum.EasingStyle.Linear), { CFrame = cf })
    if _tween then _tween:Cancel() end
    _tween = t
    t:Play()
    return t
end

local function tpto(cf)
    local char = client.Character or client.CharacterAdded:Wait()
    char:WaitForChild("HumanoidRootPart").CFrame = cf
end

-- noclip + anti-fall so the walk onto the teleporter can't get blocked or knocked off
local function farmHelper()
    local Farm = {}
    local function noclip()
        local char = client.Character
        if not char then return end
        for _, v in ipairs(char:GetChildren()) do
            if v:IsA("BasePart") then v.CanCollide = false end
        end
    end
    local conn = RunService.Stepped:Connect(noclip)
    local antifall = Instance.new("BodyVelocity")
    antifall.Velocity = Vector3.new(0, 0, 0)
    antifall.MaxForce = Vector3.new(1, 1, 1) * math.huge
    antifall.Parent = (client.Character or client.CharacterAdded:Wait()):WaitForChild("HumanoidRootPart")
    local conn2 = client.CharacterAdded:Connect(function(c)
        antifall.Parent = c:WaitForChild("HumanoidRootPart")
    end)
    function Farm:Stop()
        conn:Disconnect()
        conn2:Disconnect()
        if antifall then antifall:Destroy() end
        local char = client.Character
        if char then
            for _, v in ipairs(char:GetChildren()) do
                if v:IsA("BasePart") then v.CanCollide = true end
            end
        end
    end
    return Farm
end

--=============================== STATE: LOBBY ===============================
-- The private-code join uses a lobby-only remote; a code resolves to a private
-- instance of Map 2, empty code falls to the random-private Map 2 place.
local function joinPrivateMap2()
    if PRIVATE_CODE ~= "" then
        ReplicatedStorage:WaitForChild("handle_privateserver"):InvokeServer("join", PRIVATE_CODE, MAP2_PUBLIC)
    else
        TeleportService:Teleport(MAP2_PRIVATE, client)
    end
end

--=============================== STATE: MAP 2 ===============================
-- Train is up the first 10 minutes of every hour. Wait for that window, ensure a
-- ticket, then walk onto the chosen teleporter to board -> teleports us to Mugen.
local function inTrainWindow()
    local minuteOfHour = (tick() / 60) % 60
    return minuteOfHour > 0 and minuteOfHour < 10
end

-- Leader gate: never board unless LEADER_NAME is in this server (so an alt never
-- rides Mugen alone if the main account isn't there). No gate if it's empty, and
-- the leader account itself always passes. Case-insensitive; matches name or display.
-- Ready = leader is here AND his character is fully loaded (HRP present). Presence
-- alone isn't enough - boarding the instant his name appears (before he's spawned)
-- is what breaks the run generation.
local function leaderReady()
    if LEADER_NAME == "" then return true end
    local want = LEADER_NAME:lower()
    if client.Name:lower() == want then return true end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == want or p.DisplayName:lower() == want then
            local ch = p.Character
            return ch ~= nil and ch:FindFirstChild("HumanoidRootPart") ~= nil
        end
    end
    return false
end

local function boardTrain()
    local helper = farmHelper()

    -- GATE: wait for the window + artu2 LOADED continuously for LEADER_STABLE_SECS.
    -- This only confirms the group IS running this hour. Once confirmed we COMMIT -
    -- we do NOT re-check his presence after, because by boarding time he may have
    -- already stepped on his own teleporter and left Map 2. Re-checking here is what
    -- made the slower alts abort and never follow him in ("only some go").
    if LEADER_NAME ~= "" and client.Name:lower() ~= LEADER_NAME:lower() then
        local stableSince
        local warned = false
        while true do
            if inTrainWindow() and leaderReady() then
                stableSince = stableSince or tick()
                if tick() - stableSince >= LEADER_STABLE_SECS then break end
            else
                stableSince = nil
                if inTrainWindow() and not warned then
                    warn("[MugenLoop] holding - leader '" .. LEADER_NAME .. "' not loaded yet. Will not board alone.")
                    warned = true
                end
            end
            task.wait(0.25)
        end
    else
        while not inTrainWindow() do task.wait(0.5) end   -- leader/no-gate: just wait the window
    end

    -- SETTLE: let the run finish generating and stagger the alts so they don't all
    -- touch a teleporter on the same frame. Then we're committed for this cycle.
    task.wait(BOARD_DELAY + math.random() * BOARD_JITTER)

    -- ticket: fire the purchase (no-op if we already hold one)
    pcall(function() ReplicatedStorage:WaitForChild("purchase_mugen_ticket", 5):FireServer(1) end)
    task.wait(0.3)

    -- BOARD with retry: try the chosen slot first, then fall through the rest (covers a
    -- full/occupied seat, which was the OTHER reason some alts never made it in). A
    -- successful board teleports us out and the script re-execs in the Mugen place, so
    -- if we're still running after a touch, that slot didn't take - move to the next.
    local slot = math.clamp(math.floor(TELEPORTER_SLOT), 1, 10)
    local order = { slot }
    for i = 1, 10 do if i ~= slot then order[#order + 1] = i end end

    local deadline = tick() + 120
    while inTrainWindow() and tick() < deadline do
        local mt  = workspace:FindFirstChild("MugenTrain")
        local tps = mt and mt:FindFirstChild("Teleporters")
        if tps then
            for _, i in ipairs(order) do
                local tp = tps:FindFirstChild("Teleport" .. i)
                if tp then
                    local pos = tp:GetModelCFrame().Position
                    tweento(CFrame.new(pos)).Completed:Wait()  -- walk in so the Touch fires (proven method)
                    task.wait(0.4)
                    tpto(CFrame.new(pos))
                    task.wait(1.5)                              -- if it took, the teleport kills us here
                end
            end
        end
        task.wait(1)
    end
    helper:Stop()
    -- boarding teleports us into the Mugen place; the queued re-exec takes over there.
end

--=============================== STATE: MUGEN ===============================
-- Leave when the run ends (Cutscene10) or when a failsafe timer fires, then head
-- back to the Lobby so the private-join loop can start the next cycle.
local function fightAndLeave()
    local left = false
    local function leave()
        if left then return end
        left = true
        pcall(function()
            local map = workspace:FindFirstChild("Map")
            local carriage = map and map:FindFirstChild("Carriage")
            local prox = carriage and carriage:FindFirstChild("MenuTeleportProximity", true)
            if prox and fireproximityprompt then
                tpto(prox.Parent.CFrame); task.wait(0.5); fireproximityprompt(prox); task.wait(1.5)
            end
        end)
        TeleportService:Teleport(LOBBY, client)   -- guarantees we're back where the private join works
    end

    -- run-end signal
    task.spawn(function()
        local ok, mtrain = pcall(function() return ReplicatedStorage:WaitForChild("MugenTrain", math.huge) end)
        if ok and mtrain then
            local cs = mtrain:WaitForChild("Cutscene10", math.huge)
            cs.OnClientEvent:Once(function()
                task.wait(6)   -- let the reward window settle before bailing
                leave()
            end)
        end
    end)

    -- optional force-leave timer
    if FORCE_LEAVE_AFTER and FORCE_LEAVE_AFTER > 0 then
        task.delay(FORCE_LEAVE_AFTER, leave)
    end

    -- hard cap so we never hang in the Mugen place
    task.delay(MAX_RUN_SECONDS, leave)
end

--================================= DRIVER ===================================
queuePersist()

task.spawn(function()
    task.wait(1)
    if inLobby() then
        joinPrivateMap2()
    elseif inMap2() then
        boardTrain()
    elseif inMugen() then
        fightAndLeave()
    else
        -- Hub or anywhere unexpected -> route back to the Lobby to start the loop
        TeleportService:Teleport(LOBBY, client)
    end
end)

warn("[MugenLoop] loaded @ placeId " .. tostring(placeId) .. " | slot " .. tostring(TELEPORTER_SLOT) .. " | code '" .. PRIVATE_CODE .. "'")
