local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("ODMG"):WaitForChild("Config"):WaitForChild("ODMGConfig"))

local ODMGStateService = {}
local playerStates = setmetatable({}, { __mode = "k" })
local playerConnections = setmetatable({}, { __mode = "k" })
local cleanupHandlers = {}
local characterAddedHandler
local started = false

local STATE_FOLDER_NAME = "ODMGCharacterState"
local SIDES = { "Left", "Right" }

local function disconnectList(connections)
	for _, connection in ipairs(connections or {}) do
		connection:Disconnect()
	end
	table.clear(connections or {})
end

local function disconnectCharacter(player)
	local connectionState = playerConnections[player]
	if connectionState then
		disconnectList(connectionState.Character)
	end
end

local function disconnectPlayer(player)
	local connectionState = playerConnections[player]
	playerConnections[player] = nil
	if connectionState then
		disconnectList(connectionState.Character)
		disconnectList(connectionState.Player)
	end
end

local function destroyCharacterState(character)
	if typeof(character) ~= "Instance" then
		return
	end
	local folder = character:FindFirstChild(STATE_FOLDER_NAME)
	if folder then
		folder:Destroy()
	end
	character:SetAttribute("ODMGActive", nil)
end

local function invokeCleanup(player, character, reason, clearPersistentState)
	for handlerName, handler in pairs(cleanupHandlers) do
		local ok, err = pcall(handler, player, character, reason)
		if not ok then
			warn(string.format("[ODMG State] Cleanup handler %s failed for %s: %s", handlerName, player.Name, tostring(err)))
		end
	end
	destroyCharacterState(character)
	if clearPersistentState then
		playerStates[player] = false
		player:SetAttribute("ODMGEquipped", false)
	end
end

local function bindCharacter(player, character)
	local connectionState = playerConnections[player]
	if not connectionState then
		return
	end
	disconnectCharacter(player)
	destroyCharacterState(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		table.insert(connectionState.Character, humanoid.Died:Connect(function()
			invokeCleanup(player, character, "Died", false)
		end))
	end
	table.insert(connectionState.Character, character.AncestryChanged:Connect(function()
		if character.Parent == nil or not character:IsDescendantOf(workspace) then
			invokeCleanup(player, character, "CharacterRemoved", false)
			disconnectCharacter(player)
		end
	end))
	if playerStates[player] and characterAddedHandler then
		task.defer(function()
			if player.Character ~= character or not character:IsDescendantOf(workspace) then
				return
			end
			local ok, err = pcall(characterAddedHandler, player, character)
			if not ok then
				warn(string.format("[ODMG State] Character re-equip failed for %s: %s", player.Name, tostring(err)))
			end
		end)
	end
end

local function bindPlayer(player)
	disconnectPlayer(player)
	playerStates[player] = false
	player:SetAttribute("ODMGEquipped", false)
	local connectionState = { Player = {}, Character = {} }
	playerConnections[player] = connectionState
	table.insert(connectionState.Player, player.CharacterRemoving:Connect(function(character)
		invokeCleanup(player, character, "CharacterRemoving", false)
		disconnectCharacter(player)
	end))
	table.insert(connectionState.Player, player.CharacterAdded:Connect(function(character)
		bindCharacter(player, character)
	end))
	if player.Character then
		bindCharacter(player, player.Character)
	end
end

local function getSideFolder(character, sideName)
	if sideName ~= "Left" and sideName ~= "Right" then
		return nil
	end
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local hooks = stateFolder and stateFolder:FindFirstChild("Hooks")
	return hooks and hooks:FindFirstChild(sideName) or nil
end

local function getOrCreateVector3Value(parent, name)
	if not parent then
		return nil
	end
	local value = parent:FindFirstChild(name)
	if value and not value:IsA("Vector3Value") then
		value:Destroy()
		value = nil
	end
	if not value then
		value = Instance.new("Vector3Value")
		value.Name = name
		value.Parent = parent
	end
	return value
end

function ODMGStateService.Init(_services)
end

function ODMGStateService.Start()
	if started then
		return
	end
	started = true
	for _, player in ipairs(Players:GetPlayers()) do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		invokeCleanup(player, player.Character, "PlayerRemoving", true)
		disconnectPlayer(player)
		playerStates[player] = nil
	end)
end

function ODMGStateService.RegisterCleanupHandler(name, handler)
	if type(name) ~= "string" or name == "" or type(handler) ~= "function" then
		return false
	end
	cleanupHandlers[name] = handler
	return true
end

function ODMGStateService.UnregisterCleanupHandler(name)
	cleanupHandlers[name] = nil
end

function ODMGStateService.SetCleanupHandler(handler)
	
	if type(handler) == "function" then
		cleanupHandlers.LegacyEquipment = handler
	else
		cleanupHandlers.LegacyEquipment = nil
	end
end

function ODMGStateService.SetCharacterAddedHandler(handler)
	characterAddedHandler = type(handler) == "function" and handler or nil
end

function ODMGStateService.IsEquipped(player)
	return playerStates[player] == true
end

function ODMGStateService.SetEquipped(player, equipped)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	local value = equipped == true
	playerStates[player] = value
	player:SetAttribute("ODMGEquipped", value)
	return true
end

function ODMGStateService.CreateCharacterState(player, character)
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return nil
	end
	destroyCharacterState(character)
	local folder = Instance.new("Folder")
	folder.Name = STATE_FOLDER_NAME
	folder:SetAttribute("Equipped", true)
	folder:SetAttribute("Gas", Config.MaxGas)
	folder:SetAttribute("MaxGas", Config.MaxGas)
	folder:SetAttribute("GasEmpty", false)
	folder:SetAttribute("GasGeneration", 0)
	folder:SetAttribute("LastGasDrainTime", workspace:GetServerTimeNow())
	folder:SetAttribute("Boosting", false)
	folder:SetAttribute("LeftHookActive", false)
	folder:SetAttribute("RightHookActive", false)
	folder.Parent = character

	local hooks = Instance.new("Folder")
	hooks.Name = "Hooks"
	hooks.Parent = folder
	for _, sideName in ipairs(SIDES) do
		local side = Instance.new("Folder")
		side.Name = sideName
		side:SetAttribute("Active", false)
		side:SetAttribute("ConnectionTime", 0)
		side.Parent = hooks
		local hitPosition = Instance.new("Vector3Value")
		hitPosition.Name = "HitPosition"
		hitPosition.Parent = side
		local hitPart = Instance.new("ObjectValue")
		hitPart.Name = "HitPart"
		hitPart.Parent = side
	end
	local movement = Instance.new("Folder")
	movement.Name = "Movement"
	movement:SetAttribute("Pulling", false)
	movement:SetAttribute("ActiveHookCount", 0)
	movement:SetAttribute("PullMode", "None")
	movement:SetAttribute("Generation", 0)
	movement:SetAttribute("MomentumActive", false)
	movement:SetAttribute("MomentumStartTime", 0)
	movement:SetAttribute("PreviousPulling", false)
	movement:SetAttribute("ReleaseGeneration", 0)
	movement:SetAttribute("DualHookActive", false)
	movement:SetAttribute("DualHookStartTime", 0)
	movement:SetAttribute("DualHookGeneration", 0)
	movement:SetAttribute("BoostActive", false)
	movement:SetAttribute("BoostStartTime", 0)
	movement:SetAttribute("BoostGeneration", 0)
	movement:SetAttribute("BoostMode", "None")
	movement:SetAttribute("SteeringActive", false)
	movement:SetAttribute("SteeringDirection", 0)
	movement:SetAttribute("SteeringGeneration", 0)
	movement:SetAttribute("SteeringStartTime", 0)
	movement:SetAttribute("OrbitActive", false)
	movement:SetAttribute("OrbitDirection", 0)
	movement:SetAttribute("OrbitRadius", Config.OrbitRadius)
	movement:SetAttribute("OrbitStartTime", 0)
	movement:SetAttribute("OrbitGeneration", 0)
	movement:SetAttribute("Sliding", false)
	movement:SetAttribute("SlideStartTime", 0)
	movement:SetAttribute("SlideStartSpeed", 0)
	movement:SetAttribute("SlideGeneration", 0)
	movement:SetAttribute("SlideDirection", Vector3.zero)
	movement.Parent = folder
	local pullTarget = Instance.new("Vector3Value")
	pullTarget.Name = "PullTarget"
	pullTarget.Parent = movement
	local releaseVelocity = Instance.new("Vector3Value")
	releaseVelocity.Name = "ReleaseVelocity"
	releaseVelocity.Parent = movement
	local orbitAnchor = Instance.new("Vector3Value")
	orbitAnchor.Name = "OrbitAnchor"
	orbitAnchor.Parent = movement

	for _, name in ipairs({ "Blades", "Animations", "RuntimeReferences" }) do
		local child = Instance.new("Folder")
		child.Name = name
		child.Parent = folder
	end
	character:SetAttribute("ODMGActive", true)
	if player then
		ODMGStateService.SetEquipped(player, true)
	end
	return folder
end

function ODMGStateService.GetCharacterState(character)
	return typeof(character) == "Instance" and character:FindFirstChild(STATE_FOLDER_NAME) or nil
end

function ODMGStateService.GetHookState(character, sideName)
	local side = getSideFolder(character, sideName)
	if not side then
		return nil
	end
	return {
		Active = side:GetAttribute("Active") == true,
		HitPosition = side.HitPosition.Value,
		HitPart = side.HitPart.Value,
		ConnectionTime = side:GetAttribute("ConnectionTime") or 0,
	}
end

function ODMGStateService.SetHookState(character, sideName, active, hitPosition, hitPart)
	local side = getSideFolder(character, sideName)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	if not side or not stateFolder then
		return false
	end
	local isActive = active == true
	side:SetAttribute("Active", isActive)
	side:SetAttribute("ConnectionTime", isActive and workspace:GetServerTimeNow() or 0)
	side.HitPosition.Value = isActive and hitPosition or Vector3.zero
	side.HitPart.Value = isActive and hitPart or nil
	stateFolder:SetAttribute(sideName .. "HookActive", isActive)
	return true
end

function ODMGStateService.ClearHookState(character, sideName)
	return ODMGStateService.SetHookState(character, sideName, false, Vector3.zero, nil)
end

function ODMGStateService.ClearAllHookStates(character)
	for _, sideName in ipairs(SIDES) do
		ODMGStateService.ClearHookState(character, sideName)
	end
end

function ODMGStateService.ClearCharacterState(player, character)
	destroyCharacterState(character)
	if player then
		ODMGStateService.SetEquipped(player, false)
	end
end

function ODMGStateService.GetMovementState(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	local pullTarget = movement and movement:FindFirstChild("PullTarget")
	local releaseVelocity = movement and movement:FindFirstChild("ReleaseVelocity")
	local orbitAnchor = getOrCreateVector3Value(movement, "OrbitAnchor")
	if not movement or not pullTarget or not releaseVelocity or not orbitAnchor then
		return nil
	end
	return {
		Pulling = movement:GetAttribute("Pulling") == true,
		ActiveHookCount = movement:GetAttribute("ActiveHookCount") or 0,
		PullTarget = pullTarget.Value,
		PullMode = movement:GetAttribute("PullMode") or "None",
		Generation = movement:GetAttribute("Generation") or 0,
		MomentumActive = movement:GetAttribute("MomentumActive") == true,
		ReleaseVelocity = releaseVelocity.Value,
		MomentumStartTime = movement:GetAttribute("MomentumStartTime") or 0,
		PreviousPulling = movement:GetAttribute("PreviousPulling") == true,
		ReleaseGeneration = movement:GetAttribute("ReleaseGeneration") or 0,
		DualHookActive = movement:GetAttribute("DualHookActive") == true,
		DualHookStartTime = movement:GetAttribute("DualHookStartTime") or 0,
		DualHookGeneration = movement:GetAttribute("DualHookGeneration") or 0,
		BoostActive = movement:GetAttribute("BoostActive") == true,
		BoostStartTime = movement:GetAttribute("BoostStartTime") or 0,
		BoostGeneration = movement:GetAttribute("BoostGeneration") or 0,
		BoostMode = movement:GetAttribute("BoostMode") or "None",
		SteeringActive = movement:GetAttribute("SteeringActive") == true,
		SteeringDirection = movement:GetAttribute("SteeringDirection") or 0,
		SteeringGeneration = movement:GetAttribute("SteeringGeneration") or 0,
		SteeringStartTime = movement:GetAttribute("SteeringStartTime") or 0,
		OrbitActive = movement:GetAttribute("OrbitActive") == true,
		OrbitDirection = movement:GetAttribute("OrbitDirection") or 0,
		OrbitAnchor = orbitAnchor.Value,
		OrbitRadius = movement:GetAttribute("OrbitRadius") or Config.OrbitRadius,
		OrbitStartTime = movement:GetAttribute("OrbitStartTime") or 0,
		OrbitGeneration = movement:GetAttribute("OrbitGeneration") or 0,
		Sliding = movement:GetAttribute("Sliding") == true,
		SlideStartTime = movement:GetAttribute("SlideStartTime") or 0,
		SlideStartSpeed = movement:GetAttribute("SlideStartSpeed") or 0,
		SlideGeneration = movement:GetAttribute("SlideGeneration") or 0,
		SlideDirection = movement:GetAttribute("SlideDirection") or Vector3.zero,
	}
end

function ODMGStateService.SetMovementState(character, pulling, activeHookCount, pullTarget, pullMode)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	local targetValue = movement and movement:FindFirstChild("PullTarget")
	if not movement or not targetValue then
		return false
	end
	local nextPulling = pulling == true
	local nextCount = math.clamp(tonumber(activeHookCount) or 0, 0, 2)
	local nextTarget = typeof(pullTarget) == "Vector3" and pullTarget or Vector3.zero
	local nextMode = table.find({ "None", "Left", "Right", "Dual" }, pullMode) and pullMode or "None"
	local nextDualActive = nextPulling and nextCount == 2 and nextMode == "Dual"
	local wasDualActive = movement:GetAttribute("DualHookActive") == true
	local changed = movement:GetAttribute("Pulling") ~= nextPulling
		or movement:GetAttribute("ActiveHookCount") ~= nextCount
		or movement:GetAttribute("PullMode") ~= nextMode
		or (targetValue.Value - nextTarget).Magnitude > 0.01
	movement:SetAttribute("Pulling", nextPulling)
	movement:SetAttribute("ActiveHookCount", nextCount)
	movement:SetAttribute("PullMode", nextMode)
	targetValue.Value = nextTarget
	if changed then
		movement:SetAttribute("Generation", (movement:GetAttribute("Generation") or 0) + 1)
	end
	if nextDualActive then
		if not wasDualActive then
			movement:SetAttribute("DualHookStartTime", workspace:GetServerTimeNow())
			movement:SetAttribute("DualHookGeneration", (movement:GetAttribute("DualHookGeneration") or 0) + 1)
		end
		movement:SetAttribute("DualHookActive", true)
	else
		movement:SetAttribute("DualHookActive", false)
		movement:SetAttribute("DualHookStartTime", 0)
	end
	return true
end

function ODMGStateService.SetPreviousPulling(character, pulling)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if not movement then
		return false
	end
	movement:SetAttribute("PreviousPulling", pulling == true)
	return true
end

function ODMGStateService.BeginMomentum(character, releaseVelocity)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	local velocityValue = movement and movement:FindFirstChild("ReleaseVelocity")
	if not movement or not velocityValue or typeof(releaseVelocity) ~= "Vector3" then
		return false
	end
	local generation = (movement:GetAttribute("Generation") or 0) + 1
	movement:SetAttribute("Generation", generation)
	movement:SetAttribute("MomentumActive", true)
	movement:SetAttribute("MomentumStartTime", workspace:GetServerTimeNow())
	movement:SetAttribute("PreviousPulling", false)
	movement:SetAttribute("ReleaseGeneration", generation)
	velocityValue.Value = releaseVelocity
	return true
end

function ODMGStateService.EndMomentum(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	local velocityValue = movement and movement:FindFirstChild("ReleaseVelocity")
	if not movement or not velocityValue then
		return false
	end
	movement:SetAttribute("MomentumActive", false)
	movement:SetAttribute("MomentumStartTime", 0)
	movement:SetAttribute("ReleaseGeneration", 0)
	velocityValue.Value = Vector3.zero
	return true
end

function ODMGStateService.GetGas(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	if not stateFolder then
		return nil
	end
	return {
		Gas = stateFolder:GetAttribute("Gas") or 0,
		MaxGas = stateFolder:GetAttribute("MaxGas") or Config.MaxGas,
		GasEmpty = stateFolder:GetAttribute("GasEmpty") == true,
		GasGeneration = stateFolder:GetAttribute("GasGeneration") or 0,
		LastGasDrainTime = stateFolder:GetAttribute("LastGasDrainTime") or 0,
	}
end

function ODMGStateService.SetGas(character, amount)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	if not stateFolder then
		return false
	end
	local maxGas = tonumber(stateFolder:GetAttribute("MaxGas")) or Config.MaxGas
	local previousGas = tonumber(stateFolder:GetAttribute("Gas")) or maxGas
	local nextGas = math.clamp(tonumber(amount) or 0, 0, maxGas)
	local gasChanged = math.abs(previousGas - nextGas) > 0.001
	stateFolder:SetAttribute("Gas", nextGas)
	stateFolder:SetAttribute("GasEmpty", nextGas <= 0)
	stateFolder:SetAttribute("LastGasDrainTime", workspace:GetServerTimeNow())
	if gasChanged then
		stateFolder:SetAttribute("GasGeneration", (stateFolder:GetAttribute("GasGeneration") or 0) + 1)
	end
	return true
end

function ODMGStateService.DrainGas(character, amount)
	local gasState = ODMGStateService.GetGas(character)
	if not gasState then
		return false
	end
	local drainAmount = math.max(tonumber(amount) or 0, 0)
	return ODMGStateService.SetGas(character, gasState.Gas - drainAmount)
end

function ODMGStateService.HasGas(character)
	local gasState = ODMGStateService.GetGas(character)
	return gasState and gasState.Gas > 0 and gasState.GasEmpty ~= true or false
end

function ODMGStateService.IsGasEmpty(character)
	local gasState = ODMGStateService.GetGas(character)
	return not gasState or gasState.GasEmpty == true or gasState.Gas <= 0
end

function ODMGStateService.ClearGasState(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	if not stateFolder then
		return false
	end
	stateFolder:SetAttribute("Gas", nil)
	stateFolder:SetAttribute("MaxGas", nil)
	stateFolder:SetAttribute("GasEmpty", nil)
	stateFolder:SetAttribute("LastGasDrainTime", nil)
	stateFolder:SetAttribute("GasGeneration", nil)
	return true
end

function ODMGStateService.SetBoosting(character, active, boostMode)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if not movement then
		return false
	end
	local nextActive = active == true
	local nextMode = table.find({ "None", "Single", "Dual", "Momentum" }, boostMode) and boostMode or "None"
	if not nextActive then
		nextMode = "None"
	end
	local changed = movement:GetAttribute("BoostActive") ~= nextActive
		or movement:GetAttribute("BoostMode") ~= nextMode
	if nextActive then
		if changed then
			movement:SetAttribute("BoostGeneration", (movement:GetAttribute("BoostGeneration") or 0) + 1)
			movement:SetAttribute("BoostStartTime", workspace:GetServerTimeNow())
		end
		movement:SetAttribute("BoostActive", true)
		movement:SetAttribute("BoostMode", nextMode)
		stateFolder:SetAttribute("Boosting", true)
	else
		movement:SetAttribute("BoostActive", false)
		movement:SetAttribute("BoostStartTime", 0)
		movement:SetAttribute("BoostMode", "None")
		stateFolder:SetAttribute("Boosting", false)
	end
	return true
end

function ODMGStateService.IsBoosting(character)
	local state = ODMGStateService.GetBoostState(character)
	return state and state.BoostActive == true or false
end

function ODMGStateService.GetBoostState(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if not movement then
		return nil
	end
	return {
		BoostActive = movement:GetAttribute("BoostActive") == true,
		BoostStartTime = movement:GetAttribute("BoostStartTime") or 0,
		BoostGeneration = movement:GetAttribute("BoostGeneration") or 0,
		BoostMode = movement:GetAttribute("BoostMode") or "None",
	}
end

function ODMGStateService.ClearBoostState(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if movement then
		movement:SetAttribute("BoostActive", false)
		movement:SetAttribute("BoostStartTime", 0)
		movement:SetAttribute("BoostGeneration", 0)
		movement:SetAttribute("BoostMode", "None")
	end
	if stateFolder then
		stateFolder:SetAttribute("Boosting", false)
	end
	return movement ~= nil
end

function ODMGStateService.SetSteeringState(character, direction, active)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if not movement then
		return false
	end
	local nextDirection = math.clamp(math.round(tonumber(direction) or 0), -1, 1)
	local nextActive = active == true and nextDirection ~= 0
	local changed = movement:GetAttribute("SteeringDirection") ~= nextDirection
		or movement:GetAttribute("SteeringActive") ~= nextActive
	movement:SetAttribute("SteeringDirection", nextDirection)
	movement:SetAttribute("SteeringActive", nextActive)
	if nextActive then
		if changed then
			movement:SetAttribute("SteeringGeneration", (movement:GetAttribute("SteeringGeneration") or 0) + 1)
			movement:SetAttribute("SteeringStartTime", workspace:GetServerTimeNow())
		end
	else
		movement:SetAttribute("SteeringStartTime", 0)
	end
	return true
end

function ODMGStateService.SetOrbitState(character, active, direction, anchor, radius)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	local orbitAnchor = getOrCreateVector3Value(movement, "OrbitAnchor")
	if not movement or not orbitAnchor then
		return false
	end
	local nextDirection = math.clamp(math.round(tonumber(direction) or 0), -1, 1)
	local nextActive = active == true and nextDirection ~= 0 and typeof(anchor) == "Vector3"
	local nextRadius = math.max(tonumber(radius) or Config.OrbitRadius, 0)
	local wasOrbitActive = movement:GetAttribute("OrbitActive") == true
	local changed = movement:GetAttribute("OrbitActive") ~= nextActive
		or movement:GetAttribute("OrbitDirection") ~= nextDirection
		or (orbitAnchor.Value - (typeof(anchor) == "Vector3" and anchor or Vector3.zero)).Magnitude > 0.01
		or math.abs((movement:GetAttribute("OrbitRadius") or Config.OrbitRadius) - nextRadius) > 0.01
	movement:SetAttribute("OrbitActive", nextActive)
	movement:SetAttribute("OrbitDirection", nextActive and nextDirection or 0)
	movement:SetAttribute("OrbitRadius", nextActive and nextRadius or Config.OrbitRadius)
	if nextActive and not wasOrbitActive then
		movement:SetAttribute("OrbitStartTime", workspace:GetServerTimeNow())
	elseif not nextActive then
		movement:SetAttribute("OrbitStartTime", 0)
	end
	orbitAnchor.Value = nextActive and anchor or Vector3.zero
	if changed then
		movement:SetAttribute("OrbitGeneration", (movement:GetAttribute("OrbitGeneration") or 0) + 1)
	end
	return true
end

function ODMGStateService.ClearOrbitState(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	local orbitAnchor = getOrCreateVector3Value(movement, "OrbitAnchor")
	if not movement or not orbitAnchor then
		return false
	end
	movement:SetAttribute("OrbitActive", false)
	movement:SetAttribute("OrbitDirection", 0)
	movement:SetAttribute("OrbitRadius", Config.OrbitRadius)
	movement:SetAttribute("OrbitStartTime", 0)
	movement:SetAttribute("OrbitGeneration", 0)
	orbitAnchor.Value = Vector3.zero
	return true
end

function ODMGStateService.ClearSteeringState(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if not movement then
		return false
	end
	movement:SetAttribute("SteeringActive", false)
	movement:SetAttribute("SteeringDirection", 0)
	movement:SetAttribute("SteeringGeneration", 0)
	movement:SetAttribute("SteeringStartTime", 0)
	return true
end

function ODMGStateService.SetSliding(character, active, startSpeed, direction)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if not movement then
		return false
	end
	local nextActive = active == true
	local wasActive = movement:GetAttribute("Sliding") == true
	if not nextActive then
		return ODMGStateService.ClearSlideState(character)
	end
	local nextSpeed = math.max(tonumber(startSpeed) or 0, 0)
	local nextDirection = typeof(direction) == "Vector3" and direction or Vector3.zero
	local horizontalDirection = Vector3.new(nextDirection.X, 0, nextDirection.Z)
	if horizontalDirection.Magnitude > 0.001 then
		horizontalDirection = horizontalDirection.Unit
	else
		horizontalDirection = Vector3.zero
	end
	movement:SetAttribute("Sliding", true)
	movement:SetAttribute("SlideStartSpeed", nextSpeed)
	movement:SetAttribute("SlideDirection", horizontalDirection)
	if not wasActive then
		movement:SetAttribute("SlideStartTime", workspace:GetServerTimeNow())
		movement:SetAttribute("SlideGeneration", (movement:GetAttribute("SlideGeneration") or 0) + 1)
	end
	return true
end

function ODMGStateService.ClearSlideState(character)
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if not movement then
		return false
	end
	movement:SetAttribute("Sliding", false)
	movement:SetAttribute("SlideStartTime", 0)
	movement:SetAttribute("SlideStartSpeed", 0)
	movement:SetAttribute("SlideGeneration", 0)
	movement:SetAttribute("SlideDirection", Vector3.zero)
	return true
end

function ODMGStateService.ClearMovementState(character)
	local cleared = ODMGStateService.SetMovementState(character, false, 0, Vector3.zero, "None")
	local stateFolder = ODMGStateService.GetCharacterState(character)
	local movement = stateFolder and stateFolder:FindFirstChild("Movement")
	if movement then
		movement:SetAttribute("DualHookActive", false)
		movement:SetAttribute("DualHookStartTime", 0)
		movement:SetAttribute("DualHookGeneration", 0)
	end
	ODMGStateService.ClearBoostState(character)
	ODMGStateService.ClearSteeringState(character)
	ODMGStateService.ClearOrbitState(character)
	ODMGStateService.ClearSlideState(character)
	ODMGStateService.EndMomentum(character)
	ODMGStateService.SetPreviousPulling(character, false)
	return cleared
end

function ODMGStateService.CleanupCharacter(player, character, reason, clearPersistentState)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	invokeCleanup(player, character, reason or "ManualCleanup", clearPersistentState == true)
	return true
end

function ODMGStateService.ResetPlayer(player, reason)
	invokeCleanup(player, player and player.Character, reason or "ManualReset", true)
end

return ODMGStateService
