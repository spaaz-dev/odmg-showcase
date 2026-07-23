local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ODMG = ReplicatedStorage:WaitForChild("ODMG")
local Config = require(ODMG:WaitForChild("Config"):WaitForChild("ODMGConfig"))
local Util = require(ODMG:WaitForChild("SharedModules"):WaitForChild("ODMGUtil"))
local replicateHookState = ODMG:WaitForChild("Remotes"):WaitForChild("ReplicateHookState")

local ODMGVisualController = {}
local visuals = setmetatable({}, { __mode = "k" })
local eventStates = setmetatable({}, { __mode = "k" })
local playerConnections = setmetatable({}, { __mode = "k" })
local visualFolder
local started = false

local function debugLog(player, sideName, sequence, formatString, ...)
	if Config.DebugGrapples then
		print(string.format(
			"[ODMG Visual %.3f] player=%s side=%s seq=%s " .. formatString,
			os.clock(), player and player.Name or "nil", sideName or "nil", tostring(sequence or 0), ...
		))
	end
end

local function getPlayerSides(store, player)
	local sides = store[player]
	if not sides then
		sides = {}
		store[player] = sides
	end
	return sides
end

local function getEventState(player, sideName)
	local sides = getPlayerSides(eventStates, player)
	if not sides[sideName] then
		sides[sideName] = { Sequence = 0, Active = false, Version = 0 }
	end
	return sides[sideName]
end

local function destroyVisual(player, sideName)
	local visual = visuals[player] and visuals[player][sideName]
	if visual then
		local sequence = getEventState(player, sideName).Sequence
		visual:Destroy()
		visuals[player][sideName] = nil
		debugLog(player, sideName, sequence, "event=BeamDestroyed")
	end
end

local function clearPlayer(player)
	for _, sideName in ipairs({ "Left", "Right" }) do
		local state = getEventState(player, sideName)
		state.Version += 1
		state.Sequence = 0
		state.Active = false
		destroyVisual(player, sideName)
	end
end

local function createVisual(sourcePlayer, sideName, hitPosition, version)
	for attempt = 1, 60 do
		local eventState = getEventState(sourcePlayer, sideName)
		if eventState.Version ~= version or not eventState.Active then
			return
		end
		local character = sourcePlayer.Character
		local originAttachment = character and Util.GetHookOrigin(character, sideName)
		if originAttachment then
			local targetPart = Instance.new("Part")
			targetPart.Name = string.format("%s_%sHookVisual", sourcePlayer.Name, sideName)
			targetPart.Size = Vector3.new(0.1, 0.1, 0.1)
			targetPart.CFrame = CFrame.new(hitPosition)
			targetPart.Anchored = true
			targetPart.Transparency = 1
			targetPart.CanCollide = false
			targetPart.CanTouch = false
			targetPart.CanQuery = false
			targetPart.Parent = visualFolder

			local targetAttachment = Instance.new("Attachment")
			targetAttachment.Name = "CableHitAttachment"
			targetAttachment.Parent = targetPart

			local beam = Instance.new("Beam")
			beam.Name = "ODMG_" .. sideName .. "Cable"
			beam.Attachment0 = originAttachment
			beam.Attachment1 = targetAttachment
			beam.Width0 = 0.08
			beam.Width1 = 0.08
			beam.FaceCamera = true
			beam.LightEmission = 0.35
			beam.Color = ColorSequence.new(Color3.fromRGB(205, 210, 220))
			beam.Transparency = NumberSequence.new(0.05)
			beam.Parent = targetPart

			if eventState.Version ~= version or not eventState.Active then
				targetPart:Destroy()
				return
			end
			destroyVisual(sourcePlayer, sideName)
			getPlayerSides(visuals, sourcePlayer)[sideName] = targetPart
			debugLog(sourcePlayer, sideName, eventState.Sequence, "event=BeamCreated")
			return
		end
		task.wait()
	end
	if Config.DebugGrapples then
		warn(string.format("[ODMG Visual %.3f] player=%s side=%s seq=%d event=MissingBeam reason=OriginUnavailableAfter60Frames", os.clock(), sourcePlayer.Name, sideName, getEventState(sourcePlayer, sideName).Sequence))
	end
end

local function handleHookState(sourcePlayer, sideName, active, hitPosition, sequence)
	if typeof(sourcePlayer) ~= "Instance" or not sourcePlayer:IsA("Player") then
		if Config.DebugGrapples then warn(string.format("[ODMG Visual %.3f] event=ReplicationFailure reason=InvalidSourcePlayer", os.clock())) end
		return
	end
	if sideName ~= "Left" and sideName ~= "Right" then
		if Config.DebugGrapples then warn(string.format("[ODMG Visual %.3f] player=%s event=ReplicationFailure reason=InvalidSide", os.clock(), sourcePlayer.Name)) end
		return
	end
	sequence = type(sequence) == "number" and sequence or 0
	local state = getEventState(sourcePlayer, sideName)
	if sequence ~= 0 and sequence < state.Sequence then
		debugLog(sourcePlayer, sideName, sequence, "event=ReplicationIgnored reason=StaleEvent latest=%d", state.Sequence)
		return
	end
	if sequence ~= 0 and sequence == state.Sequence and state.Active == false and active == true then
		debugLog(sourcePlayer, sideName, sequence, "event=ReplicationIgnored reason=ApprovalAfterRelease")
		return
	end
	state.Version += 1
	state.Sequence = sequence
	state.Active = active == true
	destroyVisual(sourcePlayer, sideName)
	debugLog(sourcePlayer, sideName, sequence, "event=ReplicationReceived active=%s", tostring(state.Active))
	if state.Active and typeof(hitPosition) == "Vector3" then
		task.spawn(createVisual, sourcePlayer, sideName, hitPosition, state.Version)
	elseif state.Active then
		state.Active = false
		if Config.DebugGrapples then warn(string.format("[ODMG Visual %.3f] player=%s side=%s seq=%d event=ReplicationFailure reason=InvalidHitPosition", os.clock(), sourcePlayer.Name, sideName, sequence)) end
	end
end

local function bindPlayer(player)
	if playerConnections[player] then
		playerConnections[player]:Disconnect()
	end
	playerConnections[player] = player.CharacterRemoving:Connect(function()
		clearPlayer(player)
	end)
end

function ODMGVisualController.Init(_controllers)
	visualFolder = workspace:FindFirstChild("ODMGClientHookVisuals")
	if not visualFolder then
		visualFolder = Instance.new("Folder")
		visualFolder.Name = "ODMGClientHookVisuals"
		visualFolder.Parent = workspace
	end
end

function ODMGVisualController.Start()
	if started then
		return
	end
	started = true
	replicateHookState.OnClientEvent:Connect(handleHookState)
	for _, player in ipairs(Players:GetPlayers()) do bindPlayer(player) end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		clearPlayer(player)
		if playerConnections[player] then playerConnections[player]:Disconnect() end
		playerConnections[player] = nil
		visuals[player] = nil
		eventStates[player] = nil
	end)
end

function ODMGVisualController.ClearPlayer(player)
	clearPlayer(player)
end

return ODMGVisualController
