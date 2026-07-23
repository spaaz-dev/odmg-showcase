local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local AnimationRegistry = require(ReplicatedStorage:WaitForChild("ODMG"):WaitForChild("AnimationAssets"):WaitForChild("AnimationRegistry"))

local ODMGAnimationController = {}

local WIRED_KEYS = {
	"OdmRun",
	"ShootingGrappleLeft",
	"ShootingGrappleRight",
	"GrappleHookingLeft",
	"GrappleHookingRight",
	"GrappleHookingBothNoBoost",
	"GrappleHookingBothBoost",
	"GrappleSpinLeft",
	"GrappleSpinRight",
	"GrappleSpinBoth",
	"Falling",
	"Sliding",
	"GasCheck",
}

local LOOP_KEYS = {
	GrappleHookingLeft = true,
	GrappleHookingRight = true,
	GrappleHookingBothNoBoost = true,
	GrappleHookingBothBoost = true,
	Falling = true,
	Sliding = true,
	OdmRun = true,
}

local TRAVERSAL_LOOP_KEYS = {
	GrappleHookingLeft = true,
	GrappleHookingRight = true,
	GrappleHookingBothNoBoost = true,
	GrappleHookingBothBoost = true,
}

local ONE_SHOT_FADE = 0.05
local LOOP_FADE = 0.12
local DUAL_SPIN_START_GRACE_TIME = 0.15
local DUAL_SPIN_START_COOLDOWN = 3
local FALLING_MIN_HEIGHT = 35
local FALLING_MIN_DOWN_SPEED = 18
local ODM_RUN_ENABLED = true

local stateController
local movementController
local started = false
local heartbeatConnection
local characterConnections = {}
local currentCharacter
local humanoid
local animator
local tracks = {}
local warnedMissingIds = {}
local currentTraversalLoop
local currentRunLoop
local previousLeftActive = false
local previousRightActive = false
local previousDualActive = false
local pendingDualSpinStartSide
local pendingDualSpinStartToken = 0
local lastDualSpinStartTime = -math.huge
local cancelPendingDualSpinStart

local function disconnectCharacterConnections()
	for _, connection in ipairs(characterConnections) do
		connection:Disconnect()
	end
	table.clear(characterConnections)
end

local function normalizeAnimationId(rawId)
	if type(rawId) ~= "string" then
		return nil
	end
	local trimmed = string.gsub(rawId, "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return nil
	end
	if string.find(trimmed, "^rbxassetid://") then
		return trimmed
	end
	return "rbxassetid://" .. trimmed
end

local function warnMissingIdOnce(key)
	if warnedMissingIds[key] then
		return
	end
	warnedMissingIds[key] = true
	warn(string.format("[ODMG Animation] Missing animation asset ID for %s", key))
end

local function stopTrack(key, fadeTime)
	local track = tracks[key]
	if track and track.IsPlaying then
		track:Stop(fadeTime or LOOP_FADE)
	end
end

local function stopAllTracks(fadeTime)
	cancelPendingDualSpinStart()
	for key in pairs(tracks) do
		stopTrack(key, fadeTime or 0)
	end
	currentTraversalLoop = nil
	currentRunLoop = nil
end

local function clearTrackCache()
	stopAllTracks(0)
	table.clear(tracks)
end

local function getAnimatorForCharacter(character)
	local foundHumanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not foundHumanoid then
		return nil, nil
	end
	local foundAnimator = foundHumanoid:FindFirstChildOfClass("Animator")
	if not foundAnimator then
		foundAnimator = Instance.new("Animator")
		foundAnimator.Parent = foundHumanoid
	end
	return foundHumanoid, foundAnimator
end

local function loadTrack(key)
	if tracks[key] then
		return tracks[key]
	end
	if not animator then
		return nil
	end
	local animationId = normalizeAnimationId(AnimationRegistry[key])
	if not animationId then
		warnMissingIdOnce(key)
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = "ODMG_" .. key
	animation.AnimationId = animationId
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not ok then
		warn(string.format("[ODMG Animation] Failed to load %s: %s", key, tostring(trackOrError)))
		return nil
	end
	local track = trackOrError
	if LOOP_KEYS[key] then
		track.Looped = true
	end
	tracks[key] = track
	return track
end

local function loadAvailableTracks()
	if not animator then
		return
	end
	for _, key in ipairs(WIRED_KEYS) do
		loadTrack(key)
	end
end

local function isCharacterODMGActive()
	local character = localPlayer.Character
	return character ~= nil
		and character == currentCharacter
		and localPlayer:GetAttribute("ODMGEquipped") == true
		and character:GetAttribute("ODMGActive") == true
end

local function getMovementFolder()
	local stateFolder = currentCharacter and currentCharacter:FindFirstChild("ODMGCharacterState")
	return stateFolder and stateFolder:FindFirstChild("Movement") or nil
end

local function getMovementSnapshot()
	local localSlideState = movementController and movementController.GetSlideState and movementController.GetSlideState()
	local movement = getMovementFolder()
	local resolvedSliding
	if localSlideState ~= nil then
		resolvedSliding = localSlideState.Sliding == true
	else
		resolvedSliding = movement and movement:GetAttribute("Sliding") == true or false
	end
	if not movement then
		return {
			Pulling = false,
			ActiveHookCount = 0,
			PullMode = "None",
			MomentumActive = false,
			BoostActive = false,
			BoostMode = "None",
			OrbitActive = false,
			SteeringActive = false,
			SteeringDirection = 0,
			Sliding = resolvedSliding,
		}
	end
	return {
		Pulling = movement:GetAttribute("Pulling") == true,
		ActiveHookCount = tonumber(movement:GetAttribute("ActiveHookCount")) or 0,
		PullMode = movement:GetAttribute("PullMode") or "None",
		MomentumActive = movement:GetAttribute("MomentumActive") == true,
		BoostActive = movement:GetAttribute("BoostActive") == true,
		BoostMode = movement:GetAttribute("BoostMode") or "None",
		OrbitActive = movement:GetAttribute("OrbitActive") == true,
		SteeringActive = movement:GetAttribute("SteeringActive") == true,
		SteeringDirection = tonumber(movement:GetAttribute("SteeringDirection")) or 0,
		Sliding = resolvedSliding,
	}
end

local function getGasEmpty()
	local stateFolder = currentCharacter and currentCharacter:FindFirstChild("ODMGCharacterState")
	return stateFolder and stateFolder:GetAttribute("GasEmpty") == true or false
end

local function getHookStates()
	if not stateController then
		return false, false
	end
	local left = stateController.GetHookState(localPlayer, "Left")
	local right = stateController.GetHookState(localPlayer, "Right")
	return left and left.Active == true or false, right and right.Active == true or false
end

local function getGroundDistance()
	local root = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return 0
	end
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { currentCharacter }
	local result = workspace:Raycast(root.Position, Vector3.new(0, -500, 0), raycastParams)
	return result and (root.Position - result.Position).Magnitude or math.huge
end

local function shouldPlayFalling(leftActive, rightActive, movement, gasEmpty)
	if gasEmpty or not humanoid then
		return false
	end
	if leftActive or rightActive or movement.Pulling or movement.OrbitActive or movement.BoostActive then
		return false
	end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		return false
	end
	local root = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	return root.AssemblyLinearVelocity.Y <= -FALLING_MIN_DOWN_SPEED and getGroundDistance() >= FALLING_MIN_HEIGHT
end

local function playOneShot(key)
	if not isCharacterODMGActive() then
		return
	end
	local track = loadTrack(key)
	if not track then
		return
	end
	if track.IsPlaying then
		track:Stop(0)
	end
	track:Play(ONE_SHOT_FADE)
end

cancelPendingDualSpinStart = function()
	pendingDualSpinStartToken += 1
	pendingDualSpinStartSide = nil
end

local function scheduleDualSpinStart(sideName)
	pendingDualSpinStartToken += 1
	local token = pendingDualSpinStartToken
	pendingDualSpinStartSide = sideName
	task.delay(DUAL_SPIN_START_GRACE_TIME, function()
		if token ~= pendingDualSpinStartToken or pendingDualSpinStartSide ~= sideName then
			return
		end
		pendingDualSpinStartSide = nil
	end)
end

local function getTraversalLoopFade(key)
	return key == "Sliding" and 0.02 or LOOP_FADE
end

local function setTraversalLoop(nextLoop)
	if currentTraversalLoop == nextLoop then
		local activeTrack = nextLoop and tracks[nextLoop]
		if activeTrack and not activeTrack.IsPlaying then
			activeTrack:Play(getTraversalLoopFade(nextLoop))
		end
		return
	end
	if currentTraversalLoop then
		stopTrack(currentTraversalLoop, getTraversalLoopFade(currentTraversalLoop))
	end
	currentTraversalLoop = nil
	if nextLoop then
		local track = loadTrack(nextLoop)
		if track then
			track:Play(getTraversalLoopFade(nextLoop))
			currentTraversalLoop = nextLoop
		end
	end
end

local function setRunLoop(shouldRun)
	if not ODM_RUN_ENABLED then
		shouldRun = false
	end
	if shouldRun then
		if currentRunLoop ~= "OdmRun" then
			local track = loadTrack("OdmRun")
			if track then
				track:Play(LOOP_FADE)
				currentRunLoop = "OdmRun"
			end
		end
	else
		if currentRunLoop then
			stopTrack(currentRunLoop, LOOP_FADE)
			currentRunLoop = nil
		end
	end
end

local function resolveTraversalLoop(leftActive, rightActive, movement, gasEmpty)
	if movement.Sliding then
		return "Sliding"
	end
	if gasEmpty then
		return nil
	end
	if shouldPlayFalling(leftActive, rightActive, movement, gasEmpty) then
		return "Falling"
	end
	local activeCount = (leftActive and 1 or 0) + (rightActive and 1 or 0)
	local traversing = movement.Pulling or movement.OrbitActive or movement.MomentumActive or movement.BoostActive
	if activeCount >= 1 and traversing then
		local steeringDirection = math.clamp(math.round(tonumber(movement.SteeringDirection) or 0), -1, 1)
		if movement.OrbitActive and movement.SteeringActive and steeringDirection == -1 then
			return "GrappleHookingLeft"
		elseif movement.OrbitActive and movement.SteeringActive and steeringDirection == 1 then
			return "GrappleHookingRight"
		end
		if movement.BoostActive then
			return "GrappleHookingBothBoost"
		end
		if movement.SteeringActive and steeringDirection == -1 then
			return "GrappleHookingLeft"
		elseif movement.SteeringActive and steeringDirection == 1 then
			return "GrappleHookingRight"
		end
		return "GrappleHookingBothNoBoost"
	end
	return nil
end

local function tryPlayDualSpinStart(movement)
	if not movement or movement.BoostActive ~= true then
		return
	end
	local now = os.clock()
	if now - lastDualSpinStartTime < DUAL_SPIN_START_COOLDOWN then
		return
	end
	lastDualSpinStartTime = now
	playOneShot("GrappleSpinBoth")
end

local function updateHookOneShotTransitions(leftActive, rightActive, movement)
	local leftStarted = not previousLeftActive and leftActive
	local rightStarted = not previousRightActive and rightActive
	if leftStarted then
		playOneShot("ShootingGrappleLeft")
	end
	if rightStarted then
		playOneShot("ShootingGrappleRight")
	end

	if leftStarted and rightStarted then
		cancelPendingDualSpinStart()
		tryPlayDualSpinStart(movement)
	elseif leftStarted and rightActive then
		cancelPendingDualSpinStart()
		tryPlayDualSpinStart(movement)
	elseif rightStarted and leftActive then
		cancelPendingDualSpinStart()
		tryPlayDualSpinStart(movement)
	elseif pendingDualSpinStartSide == "Left" and rightStarted then
		cancelPendingDualSpinStart()
		tryPlayDualSpinStart(movement)
	elseif pendingDualSpinStartSide == "Right" and leftStarted then
		cancelPendingDualSpinStart()
		tryPlayDualSpinStart(movement)
	elseif leftStarted then
		scheduleDualSpinStart("Left")
	elseif rightStarted then
		scheduleDualSpinStart("Right")
	end

	if not leftActive and not rightActive then
		cancelPendingDualSpinStart()
	end
	previousLeftActive = leftActive
	previousRightActive = rightActive
	previousDualActive = leftActive and rightActive
end

local function shouldPlayOdmRun(movement, gasEmpty)
	if not isCharacterODMGActive() or gasEmpty or not humanoid then
		return false
	end
	local leftActive, rightActive = getHookStates()
	if leftActive or rightActive or movement.Pulling or movement.OrbitActive or movement.BoostActive or movement.MomentumActive or movement.Sliding then
		return false
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	local state = humanoid:GetState()
	if state ~= Enum.HumanoidStateType.Running and state ~= Enum.HumanoidStateType.RunningNoPhysics then
		return false
	end
	return humanoid.MoveDirection.Magnitude > 0.05
end

local function updateAnimationState()
	if not isCharacterODMGActive() or not humanoid or humanoid.Health <= 0 then
		stopAllTracks(0.1)
		previousLeftActive = false
		previousRightActive = false
		previousDualActive = false
		return
	end
	local movement = getMovementSnapshot()
	local gasEmpty = getGasEmpty()
	local leftActive, rightActive = getHookStates()
	updateHookOneShotTransitions(leftActive, rightActive, movement)
	if movement.Sliding and currentRunLoop then
		stopTrack(currentRunLoop, 0.02)
		currentRunLoop = nil
	end
	setTraversalLoop(resolveTraversalLoop(leftActive, rightActive, movement, gasEmpty))
	setRunLoop(shouldPlayOdmRun(movement, gasEmpty))
end

local function bindCharacter(character)
	disconnectCharacterConnections()
	clearTrackCache()
	currentCharacter = character
	humanoid, animator = getAnimatorForCharacter(character)
	previousLeftActive = false
	previousRightActive = false
	previousDualActive = false
	if humanoid then
		table.insert(characterConnections, humanoid.Died:Connect(function()
			stopAllTracks(0)
			clearTrackCache()
		end))
	end
	if character then
		table.insert(characterConnections, character.AncestryChanged:Connect(function()
			if character.Parent == nil or not character:IsDescendantOf(workspace) then
				stopAllTracks(0)
				clearTrackCache()
			end
		end))
	end
	loadAvailableTracks()
end

function ODMGAnimationController.Init(controllers)
	stateController = controllers and controllers.ODMGStateController
	movementController = controllers and controllers.ODMGMovementController
end

function ODMGAnimationController.Start()
	if started then return end
	started = true
	if localPlayer.Character then
		bindCharacter(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(bindCharacter)
	localPlayer.CharacterRemoving:Connect(function()
		stopAllTracks(0)
		clearTrackCache()
		disconnectCharacterConnections()
		currentCharacter = nil
		humanoid = nil
		animator = nil
	end)
	heartbeatConnection = RunService.Heartbeat:Connect(updateAnimationState)
end

function ODMGAnimationController.NotifySteeringPressed(direction)
	local leftActive, rightActive = getHookStates()
	if not leftActive and not rightActive then
		return
	end
	local directionValue = math.clamp(math.round(tonumber(direction) or 0), -1, 1)
	if directionValue == -1 then
		playOneShot("GrappleSpinLeft")
	elseif directionValue == 1 then
		playOneShot("GrappleSpinRight")
	end
end

function ODMGAnimationController.NotifyGasCheckRequested()
	playOneShot("GasCheck")
end

function ODMGAnimationController.StopAll()
	stopAllTracks(0)
end

function ODMGAnimationController.GetLoadedTrack(key)
	return tracks[key]
end

return ODMGAnimationController
