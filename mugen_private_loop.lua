-- ============================================================================
-- PROJECT SLAYERS - MUGEN PRIVATE-SERVER LOOP  (standalone)
-- Executor Lua (Roblox), single file. Uses the same remotes/place ids as the hub.
--
-- WHAT IT DOES (a place-driven state machine, re-runs itself on every teleport):
--   Lobby   -> join your PRIVATE Map 2 (by code, or a random low-pop private)
--   Map 2   -> the LEADER (artu2) publishes a shared board signal each hour; every
--              account reads the same instant and boards ONE train together (slot 1-10)
--   -- all accounts run on the same PC and coordinate through a shared file --
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
local PRESS_ENTRY_PROMPT= true    -- on arriving in Mugen, walk to the first E-prompt and fire it (start the run)
local ENTRY_PROMPT_NAME = ""      -- "" = nearest prompt. Or a name/action-text substring to target a specific one.
local AUTO_CHEST        = true    -- collect Loot_Chest drops during the run (ported from the hub's Auto Chest)
local SUN_IMMUNITY      = true    -- disable the client Sun_Damage script so the dream-world sun can't kill us
local MAX_RUN_SECONDS   = 720     -- hard cap in the Mugen place before bailing out (never hang forever)
local JUMP_ANTIAFK      = true   -- also jump every 60s (resets game-side AFK detection; may nudge you mid-run)
local LEADER_NAME       = "artu2" -- alts only board while THIS player is in their server. "" = no gate.
local LEADER_TRIGGER_SEC= 90      -- LEADER account only: second-of-hour it publishes the board signal (inside train window)
local BOARD_LEAD        = 4       -- seconds between the signal and the synced board (lets every alt read it first)
local SIGNAL_GRACE      = 25      -- how long the board attempt stays live past boardAt (stale-guard / retry span)
local BOARD_JITTER      = 1       -- alts add up to this many secs of sub-collision stagger after boardAt
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
local CollectionService= game:GetService("CollectionService")

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

--============================ SUN IMMUNITY ==================================
-- Disable the client Sun_Damage gameplay script so the dream-world sun can't kill us
-- during the Mugen run (ported from the hub's Sun Immunity buff). Re-armed every
-- execution and re-asserted, so it survives respawns / the game flipping it back on.
if SUN_IMMUNITY then
    task.spawn(function()
        while true do
            pcall(function()
                local ps = client:FindFirstChild("PlayerScripts")
                local sd = ps and ps:FindFirstChild("Small_Scripts")
                sd = sd and sd:FindFirstChild("Gameplay")
                sd = sd and sd:FindFirstChild("Sun_Damage")
                if sd then sd.Disabled = true end
            end)
            task.wait(3)
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

--============================ STATUS HUD ====================================
-- Corner label + heartbeat so you can glance across your instances and see each
-- account's state and that its thread is alive (uptime ticks, dot pulses). Rebuilt
-- every execution (each teleport is a fresh DataModel). Colors flag the state.
local C_WAIT  = Color3.fromRGB(240, 205, 90)   -- waiting / holding
local C_GO    = Color3.fromRGB(90, 220, 120)   -- boarding / go
local C_RUN   = Color3.fromRGB(90, 165, 240)   -- in the run
local C_LEAVE = Color3.fromRGB(240, 150, 80)   -- leaving / restarting
local setStatus
do
    local parent = (gethui and gethui()) or (get_hidden_gui and get_hidden_gui())
    if not parent then parent = pcall(function() return game:GetService("CoreGui").Name end) and game:GetService("CoreGui") or nil end
    if not parent then parent = client:WaitForChild("PlayerGui") end

    local gui = Instance.new("ScreenGui")
    gui.Name = "MugenLoopHUD"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999999
    pcall(function() gui.Parent = parent end)
    if not gui.Parent then pcall(function() gui.Parent = client:WaitForChild("PlayerGui") end) end

    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(0, 1)
    frame.Position = UDim2.new(0, 8, 1, -8)          -- bottom-left
    frame.Size = UDim2.new(0, 250, 0, 52)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    frame.BackgroundTransparency = 0.1
    frame.BorderSizePixel = 0
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame); stroke.Color = Color3.fromRGB(60, 60, 72); stroke.Thickness = 1

    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 10, 0, 10)
    dot.Position = UDim2.new(0, 12, 0, 9)
    dot.BackgroundColor3 = C_GO
    dot.BorderSizePixel = 0
    dot.Parent = frame
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 30, 0, 5)
    title.Size = UDim2.new(1, -36, 0, 16)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 12
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(235, 235, 240)
    title.Text = "MugenLoop • " .. client.Name
    title.Parent = frame

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.new(0, 12, 0, 24)
    label.Size = UDim2.new(1, -18, 0, 24)
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextWrapped = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.TextColor3 = Color3.fromRGB(205, 205, 215)
    label.Text = "starting..."
    label.Parent = frame

    local startAt = tick()
    setStatus = function(text, color)
        pcall(function()
            if text then label.Text = text end
            if color then dot.BackgroundColor3 = color end
        end)
    end

    -- heartbeat: pulse the dot + tick uptime so a frozen thread is obvious at a glance
    task.spawn(function()
        local on = false
        while gui.Parent do
            on = not on
            dot.BackgroundTransparency = on and 0 or 0.65
            local up = math.floor(tick() - startAt)
            title.Text = ("MugenLoop • %s  [%dm%02ds]"):format(client.Name, math.floor(up / 60), up % 60)
            task.wait(0.5)
        end
    end)
end

--=============================== STATE: LOBBY ===============================
-- The private-code join uses a lobby-only remote; a code resolves to a private
-- instance of Map 2, empty code falls to the random-private Map 2 place.
local function joinPrivateMap2()
    setStatus("Lobby → joining private Map 2", C_WAIT)
    if PRIVATE_CODE ~= "" then
        ReplicatedStorage:WaitForChild("handle_privateserver"):InvokeServer("join", PRIVATE_CODE, MAP2_PUBLIC)
    else
        TeleportService:Teleport(MAP2_PRIVATE, client)
    end
end

--=============================== STATE: MAP 2 ===============================
-- Leader presence: LEADER_NAME is in this server's player list. We read from the
-- player list (not his streamed-in character): with StreamingEnabled a far-away
-- leader has no HRP on our client, which would falsely read as "gone". The player
-- list is streaming-independent, so it's the reliable "is artu2 actually here" check.
local function leaderReady()
    if LEADER_NAME == "" then return true end
    local want = LEADER_NAME:lower()
    if client.Name:lower() == want then return true end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == want or p.DisplayName:lower() == want then
            return true
        end
    end
    return false
end

-- SHARED-FILE BOARD SIGNAL. All accounts run on ONE PC, so they share the executor's
-- writefile/readfile folder. Only the LEADER writes the signal ("<hourId>|<boardAt>");
-- every account (leader included) reads the SAME boardAt and boards at that instant,
-- so they hit ONE train together - the only way to be in the same run, since you
-- can't join a Mugen run once it's departed. No signal on disk = artu2 isn't running
-- = nobody boards. Sharing one number means zero clock-skew between accounts.
local SIGNAL_FILE = "FireHub/PJS/mugen_board_signal.txt"
pcall(function() if makefolder and not isfolder("FireHub/PJS") then makefolder("FireHub/PJS") end end)

local function hourId()     return math.floor(os.time() / 3600) end
local function secOfHour()  return os.time() % 3600 end

local function writeSignal(boardAt)
    pcall(function() writefile(SIGNAL_FILE, hourId() .. "|" .. boardAt) end)
end

-- Returns boardAt if a FRESH signal for THIS hour exists, else nil.
local function readSignal()
    local ok, data = pcall(function() return isfile(SIGNAL_FILE) and readfile(SIGNAL_FILE) or nil end)
    if not ok or not data then return nil end
    local h, b = data:match("^(%-?%d+)|(%-?%d+)$")
    h, b = tonumber(h), tonumber(b)
    if not h or not b then return nil end
    if h ~= hourId() then return nil end                 -- last hour's signal -> ignore
    if os.time() > b + SIGNAL_GRACE then return nil end   -- boardAt long past -> ignore
    return b
end

-- Walk onto the teleporters at/after boardAt (chosen slot first, then fall through a
-- full seat). A successful board teleports us out (script re-execs in Mugen); if we
-- stay running the seat didn't take, so we retry across the grace span.
local function attemptBoard(boardAt)
    setStatus("boarding train...", C_GO)
    local helper = farmHelper()   -- noclip + antifall for the board attempt only
    pcall(function() ReplicatedStorage:WaitForChild("purchase_mugen_ticket", 5):FireServer(1) end)
    local slot = math.clamp(math.floor(TELEPORTER_SLOT), 1, 10)
    local order = { slot }
    for i = 1, 10 do if i ~= slot then order[#order + 1] = i end end
    while os.time() <= boardAt + SIGNAL_GRACE do
        local mt  = workspace:FindFirstChild("MugenTrain")
        local tps = mt and mt:FindFirstChild("Teleporters")
        if tps then
            for _, i in ipairs(order) do
                local tp = tps:FindFirstChild("Teleport" .. i)
                if tp then
                    local pos = tp:GetModelCFrame().Position
                    tweento(CFrame.new(pos)).Completed:Wait()  -- walk in so the Touch fires
                    task.wait(0.3)
                    tpto(CFrame.new(pos))
                    task.wait(1)
                end
            end
        end
        task.wait(0.5)
    end
    helper:Stop()
end

local function boardTrain()
    local isLeader = (LEADER_NAME == "") or (client.Name:lower() == LEADER_NAME:lower())
    local handled  -- hourId we've already acted on (per execution; resets on re-exec)

    while true do
        if isLeader then
            -- LEADER: once per hour, at the trigger second, publish the shared boardAt
            -- for everyone, then board at it yourself. (You board too, so you're on the
            -- same train as the alts.)
            if secOfHour() >= LEADER_TRIGGER_SEC and handled ~= hourId() then
                local boardAt = os.time() + BOARD_LEAD
                writeSignal(boardAt)
                handled = hourId()
                warn(("[MugenLoop] LEADER published board signal | boardAt in %ds"):format(BOARD_LEAD))
                setStatus("published signal • boarding", C_GO)
                repeat task.wait(0.2) until os.time() >= boardAt
                attemptBoard(boardAt)
                warn("[MugenLoop] leader board window passed - re-arming for next hour.")
            else
                setStatus("Map 2 • leader: waiting for trigger", C_WAIT)
                task.wait(0.5)
            end
        else
            -- ALT: board only if artu2 published a fresh signal AND he's in THIS server
            -- (the file is shared PC-wide; leaderReady confirms same instance, not a
            -- different one). Then wait for the shared boardAt and board together.
            local boardAt = readSignal()
            if boardAt and handled ~= hourId() then
                if leaderReady() then
                    handled = hourId()
                    warn("[MugenLoop] board signal received - syncing to board with leader.")
                    setStatus("signal! syncing to board", C_GO)
                    repeat task.wait(0.1) until os.time() >= boardAt
                    task.wait(math.random() * BOARD_JITTER)   -- sub-second anti-collision only
                    attemptBoard(boardAt)
                    warn("[MugenLoop] alt board window passed - re-arming for next hour.")
                else
                    handled = hourId()   -- signal exists but leader isn't in our instance -> skip hour
                    warn(("[MugenLoop] signal present but leader '%s' not in THIS server - not boarding (same code on every account?)."):format(LEADER_NAME))
                    setStatus("leader not in this server!", C_LEAVE)
                end
            else
                setStatus(("Map 2 • waiting for '%s' signal"):format(LEADER_NAME), C_WAIT)
                task.wait(0.4)
            end
        end
    end
    -- (unreachable; a successful board teleports us into the Mugen place)
end

--=============================== STATE: MUGEN ===============================
-- World CFrame of whatever a ProximityPrompt is parented to (BasePart or Attachment).
local function promptCF(p)
    local par = p.Parent
    if not par then return nil end
    if par:IsA("BasePart") then return par.CFrame end
    if par:IsA("Attachment") then return par.WorldCFrame end
    return nil
end

-- On arriving in Mugen, walk to the first E-prompt and fire it (start the run). Scans
-- for up to 30s as prompts stream in; nearest prompt by default, or the one whose name
-- / action text matches ENTRY_PROMPT_NAME. Runs in the background so it can't block leave.
local function pressEntryPrompt()
    if not PRESS_ENTRY_PROMPT then return end
    task.spawn(function()
        local want = ENTRY_PROMPT_NAME:lower()
        local deadline = tick() + 30
        while tick() < deadline do
            local char = client.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local best, bestDist, bestCF
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("ProximityPrompt") and d.Enabled then
                        local match = (want == "")
                            or d.Name:lower():find(want, 1, true)
                            or (d.ActionText and d.ActionText:lower():find(want, 1, true))
                            or (d.ObjectText and d.ObjectText:lower():find(want, 1, true))
                        local cf = match and promptCF(d)
                        if cf then
                            local dist = (cf.Position - hrp.Position).Magnitude
                            if not bestDist or dist < bestDist then best, bestDist, bestCF = d, dist, cf end
                        end
                    end
                end
                if best then
                    pcall(function()
                        tpto(bestCF)
                        task.wait(0.4)
                        fireproximityprompt(best)
                    end)
                    warn("[MugenLoop] fired entry prompt: " .. best.Name)
                    return
                end
            end
            task.wait(0.5)
        end
        warn("[MugenLoop] no entry prompt found in Mugen within 30s.")
    end)
end

-- Leave when the run ends (Cutscene10) or when a failsafe timer fires, then head
-- back to the Lobby so the private-join loop can start the next cycle.
local function fightAndLeave()
    setStatus("Mugen • in run", C_RUN)
    pressEntryPrompt()   -- click the first E-prompt to start the run

    local left       = false   -- guard: leave() has started
    local collecting = true    -- Auto Chest loop runs while true

    -- AUTO CHEST: grab Loot_Chest drops as they spawn (ported from the hub's Auto Chest).
    if AUTO_CHEST then
        task.spawn(function()
            while collecting do
                for _, chest in ipairs(CollectionService:GetTagged("Chests")) do
                    if chest.Name == "Loot_Chest" then
                        local drops = chest:FindFirstChild("Drops")
                        local add   = chest:FindFirstChild("Add_To_Inventory")
                        if drops and add then
                            for _, d in ipairs(drops:GetChildren()) do
                                pcall(function() add:InvokeServer(d.Name) end)
                                d:Destroy()
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    end

    local function leave()
        if left then return end
        left = true   -- guard first so two triggers can't both run the exit
        setStatus("run over • collecting + leaving", C_LEAVE)
        -- Wait for the loot chests to finish spawning so Auto Chest grabs them before
        -- we go (ported from the hub's chest-wait: delay_chest_amount / 3.7 + buffer).
        if AUTO_CHEST then
            pcall(function()
                local dca = workspace:FindFirstChild("delay_chest_amount")
                task.wait(dca and (dca.Value / 3.7 + 6) or 6)
            end)
        end
        collecting = false   -- chests grabbed -> stop the collector
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

    -- run-end signal #1: the final cutscene fires when the run completes
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

    -- run-end signal #2 (independent fallback): the carriage's leave prompt appears
    -- when the run is over. Poll for it, but only after a minimum time so it can't
    -- false-trigger on entry. Covers a missed Cutscene10 so we don't wait the cap.
    task.spawn(function()
        local start = tick()
        while not left do
            if tick() - start > 30 then
                local map = workspace:FindFirstChild("Map")
                local carriage = map and map:FindFirstChild("Carriage")
                if carriage and carriage:FindFirstChild("MenuTeleportProximity", true) then
                    warn("[MugenLoop] run-end leave prompt detected -> leaving.")
                    leave()
                    break
                end
            end
            task.wait(2)
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
        setStatus("routing to Lobby...", C_WAIT)
        TeleportService:Teleport(LOBBY, client)
    end
end)

warn("[MugenLoop] loaded @ placeId " .. tostring(placeId) .. " | slot " .. tostring(TELEPORTER_SLOT) .. " | code '" .. PRIVATE_CODE .. "'")
