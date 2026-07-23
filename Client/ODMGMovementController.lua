local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("ODMG"):WaitForChild("Config"):WaitForChild("ODMGConfig"))

local ODMGMovementController = {}
local stateController
local inputController
local started = false
local heartbeatConnection
local attachment
local linearVelocity
local actuatorRoot
local orbitAttachment
local orbitAntiGravityForce
local orbitAntiGravityRoot
local groundLaunchUntil = 0
local previousPulling = false
local previousActiveHookCount = 0
local previousBoostActive = false
local previousBoostMode = "None"
local RELEASE_VELOCITY_SAMPLE_COUNT = 4
local releaseVelocitySamples = {}
local preparedReleaseVelocity = Vector3.zero
local preparedBoostedRelease = false
local momentumActive = false
local releaseVelocity = Vector3.zero
local lockedMomentumDirection = Vector3.zero
local momentumDirectionLocked = false
local momentumStartTime = 0
local movementGeneration = 0
local releaseGeneration = 0
local localOrbitActive = false
local localOrbitAnchor = Vector3.zero
local localOrbitRadius = 0
local localOrbitDirection = 0
local localOrbitStartTime = 0
local localOrbitTangentialSpeed = 0
local sliding = false
local slideStartTime = 0
local slideSpeed = 0
local slideDirection = Vector3.zero
local slideLastGroundedTime = 0
local previousGrounded = false
local airborneHorizontalFrame1 = Vector3.zero
local airborneHorizontalFrame2 = Vector3.zero
local slideInputBlocked = false
local playerControls
local resumeHeldMovementActive = false

local ATTACHMENT_NAME = "ODMGPullAttachment"
local ACTUATOR_NAME = "ODMGPullLinearVelocity"
local ORBIT_ATTACHMENT_NAME = "ODMGOrbitAntiGravityAttachment"
local ORBIT_FORCE_NAME = "ODMGOrbitAntiGravityForce"
local HELD_MOVEMENT_RESUME_BIND_NAME = "ODMGResumeHeldMovementAfterSlide"

local function getPlayerControls()
	if playerControls then
		return playerControls
	end
	local playerScripts = localPlayer:FindFirstChildOfClass("PlayerScripts") or localPlayer:WaitForChild("PlayerScripts", 5)
	local playerModule = playerScripts and (playerScripts:FindFirstChild("PlayerModule") or playerScripts:WaitForChild("PlayerModule", 5))
	if not playerModule then
		return nil
	end
	local ok, module = pcall(require, playerModule)
	if not ok or type(module) ~= "table" or type(module.GetControls) ~= "function" then
		return nil
	end
	playerControls = module:GetControls()
	return playerControls
end

local function cancelHeldMovementResume()
	if resumeHeldMovementActive then
		RunService:UnbindFromRenderStep(HELD_MOVEMENT_RESUME_BIND_NAME)
		resumeHeldMovementActive = false
	end
end

local function isMovementKeyDown(keyCode, alternateKeyCode)
	return UserInputService:IsKeyDown(keyCode) or UserInputService:IsKeyDown(alternateKeyCode)
end

local function getHeldMoveVector()
	local forward = isMovementKeyDown(Enum.KeyCode.W, Enum.KeyCode.Up)
	local backward = isMovementKeyDown(Enum.KeyCode.S, Enum.KeyCode.Down)
	local left = isMovementKeyDown(Enum.KeyCode.A, Enum.KeyCode.Left)
	local right = isMovementKeyDown(Enum.KeyCode.D, Enum.KeyCode.Right)
	local anyHeld = forward or backward or left or right
	local moveVector = Vector3.new((right and 1 or 0) - (left and 1 or 0), 0, (backward and 1 or 0) - (forward and 1 or 0))
	return anyHeld, moveVector
end

local function resumeHeldMovementInput()
	cancelHeldMovementResume()
	local anyHeld = getHeldMoveVector()
	if not anyHeld then
		return
	end
	resumeHeldMovementActive = true
	RunService:BindToRenderStep(HELD_MOVEMENT_RESUME_BIND_NAME, Enum.RenderPriority.Character.Value + 1, function()
		local held, moveVector = getHeldMoveVector()
		if not held or sliding then
			cancelHeldMovementResume()
			return
		end
		local character = localPlayer.Character
		local currentHumanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not currentHumanoid or currentHumanoid.Health <= 0 then
			cancelHeldMovementResume()
			return
		end
		if moveVector.Magnitude > 0.001 then
			moveVector = moveVector.Unit
		end
		currentHumanoid:Move(moveVector, true)
	end)
end

local function setSlideInputBlocked(active)
	local shouldBlock = active == true
	if slideInputBlocked == shouldBlock then
		return
	end
	slideInputBlocked = shouldBlock
	local controls = getPlayerControls()
	if shouldBlock then
		cancelHeldMovementResume()
		if controls then
			controls:Disable()
		end
	else
		if controls then
			controls:Enable()
		end
		resumeHeldMovementInput()
	end
end

local function cleanupActuator()
	if linearVelocity then
		linearVelocity:Destroy()
		linearVelocity = nil
	end
	if attachment then
		attachment:Destroy()
		attachment = nil
	end
	actuatorRoot = nil
	groundLaunchUntil = 0
end

local function cleanupOrbitAntiGravity()
	if orbitAntiGravityForce then
		orbitAntiGravityForce:Destroy()
		orbitAntiGravityForce = nil
	end
	if orbitAttachment then
		orbitAttachment:Destroy()
		orbitAttachment = nil
	end
	orbitAntiGravityRoot = nil
end

local function ensureOrbitAntiGravity(root)
	if orbitAntiGravityRoot ~= root then
		cleanupOrbitAntiGravity()
	end
	if not orbitAttachment or orbitAttachment.Parent ~= root then
		if orbitAttachment then orbitAttachment:Destroy() end
		orbitAttachment = root:FindFirstChild(ORBIT_ATTACHMENT_NAME)
		if orbitAttachment and not orbitAttachment:IsA("Attachment") then
			orbitAttachment:Destroy()
			orbitAttachment = nil
		end
		if not orbitAttachment then
			orbitAttachment = Instance.new("Attachment")
			orbitAttachment.Name = ORBIT_ATTACHMENT_NAME
			orbitAttachment.Parent = root
		end
	end
	if not orbitAntiGravityForce or orbitAntiGravityForce.Parent ~= root then
		local existing = root:FindFirstChild(ORBIT_FORCE_NAME)
		if existing then existing:Destroy() end
		orbitAntiGravityForce = Instance.new("VectorForce")
		orbitAntiGravityForce.Name = ORBIT_FORCE_NAME
		orbitAntiGravityForce.Attachment0 = orbitAttachment
		orbitAntiGravityForce.RelativeTo = Enum.ActuatorRelativeTo.World
		orbitAntiGravityForce.ApplyAtCenterOfMass = true
		orbitAntiGravityForce.Parent = root
	end
	orbitAntiGravityForce.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
	orbitAntiGravityRoot = root
end

local function clearMomentumState()
	momentumActive = false
	releaseVelocity = Vector3.zero
	lockedMomentumDirection = Vector3.zero
	momentumDirectionLocked = false
	momentumStartTime = 0
	releaseGeneration = 0
end

local function clearReleaseDirectionBuffer()
	table.clear(releaseVelocitySamples)
	preparedReleaseVelocity = Vector3.zero
	preparedBoostedRelease = false
end

local function recordReleaseVelocitySample(velocity)
	if typeof(velocity) ~= "Vector3" or velocity.Magnitude < Config.MomentumMinSpeed then
		return
	end
	table.insert(releaseVelocitySamples, velocity)
	while #releaseVelocitySamples > RELEASE_VELOCITY_SAMPLE_COUNT do
		table.remove(releaseVelocitySamples, 1)
	end
end

local function getBufferedReleaseVelocity(fallbackVelocity)
	local directionSum = Vector3.zero
	local weightedSpeed = 0
	local totalWeight = 0
	for index, sample in ipairs(releaseVelocitySamples) do
		local magnitude = sample.Magnitude
		if magnitude > 0.001 then
			local weight = index
			directionSum += sample.Unit * weight
			weightedSpeed += magnitude * weight
			totalWeight += weight
		end
	end
	if totalWeight > 0 and directionSum.Magnitude > 0.001 then
		return directionSum.Unit * (weightedSpeed / totalWeight)
	end
	return typeof(fallbackVelocity) == "Vector3" and fallbackVelocity or Vector3.zero
end

local function resetMovementState()
	cleanupActuator()
	cleanupOrbitAntiGravity()
	clearMomentumState()
	localOrbitActive = false
	localOrbitAnchor = Vector3.zero
	localOrbitRadius = 0
	localOrbitDirection = 0
	localOrbitStartTime = 0
	localOrbitTangentialSpeed = 0
	sliding = false
	setSlideInputBlocked(false)
	cancelHeldMovementResume()
	slideStartTime = 0
	slideSpeed = 0
	slideDirection = Vector3.zero
	slideLastGroundedTime = 0
	previousGrounded = false
	airborneHorizontalFrame1 = Vector3.zero
	airborneHorizontalFrame2 = Vector3.zero
	previousPulling = false
	previousActiveHookCount = 0
	previousBoostActive = false
	previousBoostMode = "None"
	clearReleaseDirectionBuffer()
	movementGeneration = 0
end

local function getReadyCharacter()
	local character = localPlayer.Character
	if not character or not character:IsDescendantOf(workspace) then
		return nil
	end
	if localPlayer:GetAttribute("ODMGEquipped") ~= true or character:GetAttribute("ODMGActive") ~= true then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return character, humanoid, root
end

local function resolveApprovedTarget()
	if not stateController then
		return nil, 0, "None", math.huge
	end
	local left = stateController.GetHookState(localPlayer, "Left")
	local right = stateController.GetHookState(localPlayer, "Right")
	local leftActive = left and left.Active and typeof(left.HitPosition) == "Vector3"
	local rightActive = right and right.Active and typeof(right.HitPosition) == "Vector3"
	if leftActive and rightActive then
		return (left.HitPosition + right.HitPosition) / 2, 2, "Dual", (left.HitPosition - right.HitPosition).Magnitude
	elseif leftActive then
		return left.HitPosition, 1, "Left", 0
	elseif rightActive then
		return right.HitPosition, 1, "Right", 0
	end
	return nil, 0, "None", math.huge
end

local function ensureActuator(root)
	if actuatorRoot ~= root then
		cleanupActuator()
	end
	if linearVelocity and linearVelocity.Parent == root and attachment and attachment.Parent == root then
		return linearVelocity
	end
	attachment = root:FindFirstChild(ATTACHMENT_NAME)
	if not attachment or not attachment:IsA("Attachment") then
		if attachment then attachment:Destroy() end
		attachment = Instance.new("Attachment")
		attachment.Name = ATTACHMENT_NAME
		attachment.Parent = root
	end
	local existing = root:FindFirstChild(ACTUATOR_NAME)
	if existing then existing:Destroy() end
	linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = ACTUATOR_NAME
	linearVelocity.Attachment0 = attachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linearVelocity.ForceLimitsEnabled = true
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Parent = root
	actuatorRoot = root
	return linearVelocity
end

local function isGroundControlState(humanoid)
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Dead
		or state == Enum.HumanoidStateType.Seated
		or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Climbing then
		return true
	end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		return state == Enum.HumanoidStateType.Running
			or state == Enum.HumanoidStateType.RunningNoPhysics
			or state == Enum.HumanoidStateType.Landed
	end
	return false
end

local function getSlideGroundContact(character, humanoid, root)
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Dead
		or state == Enum.HumanoidStateType.Seated
		or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Climbing then
		return false, nil
	end
	local validGroundState = state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
		or state == Enum.HumanoidStateType.GettingUp
		or state == Enum.HumanoidStateType.Freefall
	if not validGroundState then
		return false, nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.RespectCanCollide = true
	local probeDistance = humanoid.HipHeight + root.Size.Y * 0.5 + Config.SlideGroundProbeExtraDistance
	local result = workspace:Raycast(root.Position, Vector3.new(0, -probeDistance, 0), params)
	if not result or result.Normal.Y < 0.35 then
		return false, nil
	end
	return true, result.Normal
end

local function stopLocalSlide()
	if not sliding then
		return
	end
	sliding = false
	setSlideInputBlocked(false)
	slideStartTime = 0
	slideSpeed = 0
	slideDirection = Vector3.zero
	slideLastGroundedTime = 0
	cleanupActuator()
end

local function beginLocalSlide(root, groundNormal, entryHorizontalVelocity)
	local velocity = root.AssemblyLinearVelocity
	local currentHorizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local horizontalVelocity = typeof(entryHorizontalVelocity) == "Vector3" and entryHorizontalVelocity or currentHorizontalVelocity
	horizontalVelocity = Vector3.new(horizontalVelocity.X, 0, horizontalVelocity.Z)
	local horizontalSpeed = horizontalVelocity.Magnitude
	if horizontalSpeed < Config.SlideEntryMinSpeed then
		return false
	end
	local normal = typeof(groundNormal) == "Vector3" and groundNormal or Vector3.yAxis
	local planeVelocity = horizontalVelocity - normal * horizontalVelocity:Dot(normal)
	if planeVelocity.Magnitude <= 0.001 then
		return false
	end
	sliding = true
	setSlideInputBlocked(true)
	slideStartTime = os.clock()
	slideSpeed = horizontalSpeed
	slideDirection = planeVelocity.Unit
	slideLastGroundedTime = slideStartTime
	cleanupActuator()
	cleanupOrbitAntiGravity()
	return true
end

local function updateLocalSlide(deltaTime, root, grounded, groundNormal)
	if not sliding then
		return false
	end
	local now = os.clock()
	if grounded then
		slideLastGroundedTime = now
	elseif now - slideLastGroundedTime > Config.SlideGroundGraceTime then
		stopLocalSlide()
		return false
	end
	if now - slideStartTime >= Config.SlideMaxDuration then
		stopLocalSlide()
		return false
	end
	slideSpeed = math.max(slideSpeed - Config.SlideDeceleration * math.max(deltaTime, 0), 0)
	local horizontalVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	if slideSpeed <= Config.SlideExitSpeed
		or (now - slideStartTime > 0.15 and horizontalVelocity.Magnitude < Config.SlideExitSpeed) then
		stopLocalSlide()
		return false
	end
	if grounded and typeof(groundNormal) == "Vector3" then
		local projected = slideDirection - groundNormal * slideDirection:Dot(groundNormal)
		if projected.Magnitude > 0.001 then
			slideDirection = projected.Unit
		end
	end
	local horizontalDirection = Vector3.new(slideDirection.X, 0, slideDirection.Z)
	if horizontalDirection.Magnitude <= 0.001 then
		stopLocalSlide()
		return false
	end
	local actuator = ensureActuator(root)
	local horizontalForce = math.max(root.AssemblyMass * Config.SlideForceAcceleration, 1)
	local groundingForce = math.max(root.AssemblyMass * Config.SlideGroundingAcceleration, 1)
	actuator.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	actuator.MaxAxesForce = Vector3.new(horizontalForce, groundingForce, horizontalForce)
	actuator.VectorVelocity = horizontalDirection.Unit * slideSpeed + Vector3.new(0, -Config.SlideGroundingDownSpeed, 0)
	return true
end

local function getSteeringStrength(isDualHook, boostActive, momentumMode)
	if momentumMode then
		return Config.MomentumAirSteerStrength
	end
	if boostActive then
		return Config.BoostAirSteerStrength
	end
	if isDualHook then
		return Config.DualHookAirSteerStrength
	end
	return Config.AirSteerStrength
end

local function applySteering(baseVelocity, root, steeringState, isDualHook, boostActive, momentumMode, safetyCap)
	if not steeringState or steeringState.SteeringActive ~= true then
		return baseVelocity, false
	end
	local directionValue = math.clamp(math.round(tonumber(steeringState.SteeringDirection) or 0), -1, 1)
	if directionValue == 0 then
		return baseVelocity, false
	end
	local traversalSource = baseVelocity.Magnitude > 0.001 and baseVelocity or root.AssemblyLinearVelocity
	if traversalSource.Magnitude <= 0.001 then
		return baseVelocity, false
	end
	local traversalDirection = traversalSource.Unit
	local camera = workspace.CurrentCamera
	local cameraRight = camera and camera.CFrame.RightVector or root.CFrame.RightVector
	local steeringRight = cameraRight - traversalDirection * cameraRight:Dot(traversalDirection)
	if steeringRight.Magnitude <= 0.001 then
		local fallback = traversalDirection:Cross(Vector3.yAxis)
		steeringRight = fallback.Magnitude > 0.001 and fallback or root.CFrame.RightVector
	end
	steeringRight = steeringRight.Unit
	local strength = math.min(getSteeringStrength(isDualHook, boostActive, momentumMode), Config.AirSteerMaxLateralSpeed)
	local steeredVelocity = baseVelocity + steeringRight * directionValue * strength
	if safetyCap and safetyCap > 0 and steeredVelocity.Magnitude > safetyCap then
		steeredVelocity = steeredVelocity.Unit * safetyCap
	end
	return steeredVelocity, true
end

local function computeOrbitVelocity(root, orbitState, boostActive, safetyCap)
	if not orbitState or orbitState.OrbitActive ~= true then
		return nil
	end
	local directionValue = math.clamp(math.round(tonumber(orbitState.OrbitDirection) or 0), -1, 1)
	if directionValue == 0 or typeof(orbitState.OrbitAnchor) ~= "Vector3" then
		return nil
	end
	local anchor = orbitState.OrbitAnchor
	local radius = math.max(tonumber(orbitState.OrbitRadius) or Config.OrbitRadius, 0.001)
	local orbitStartTime = tonumber(orbitState.OrbitStartTime) or 0
	if orbitStartTime > 0 then
		local elapsed = math.max(os.clock() - orbitStartTime, 0)
		radius = math.max(Config.OrbitMinimumRadius, radius - Config.OrbitRadiusShrinkRate * elapsed)
	end
	local offsetFromAnchor = root.Position - anchor
	local distance = offsetFromAnchor.Magnitude
	if distance <= 0.001 then
		return nil
	end
	local radialDirection = offsetFromAnchor.Unit
	local tangent = Vector3.yAxis:Cross(radialDirection)
	if tangent.Magnitude <= 0.001 then
		local camera = workspace.CurrentCamera
		local cameraRight = camera and camera.CFrame.RightVector or root.CFrame.RightVector
		tangent = cameraRight - radialDirection * cameraRight:Dot(radialDirection)
	end
	if tangent.Magnitude <= 0.001 then
		return nil
	end
	tangent = tangent.Unit * directionValue
	local dynamicTangentialSpeed = tonumber(orbitState.OrbitTangentialSpeed)
	local fallbackTangentialSpeed = boostActive and Config.BoostOrbitTangentialSpeed or Config.OrbitTangentialSpeed
	local tangentSpeed = math.clamp(dynamicTangentialSpeed or fallbackTangentialSpeed, 0, safetyCap)
	local radiusError = radius - distance
	local correctionSpeed = 0
	if math.abs(radiusError) > Config.OrbitRadiusTolerance then
		correctionSpeed = math.clamp(radiusError * Config.OrbitRadialCorrectionStrength, -safetyCap, safetyCap)
	end
	local radialVelocity = root.AssemblyLinearVelocity:Dot(radialDirection)
	local inwardSpeed = math.max(-radialVelocity, 0)
	local brakeBand = math.max(Config.OrbitRadiusTolerance, inwardSpeed * Config.OrbitRadialBrakeTime)
	if inwardSpeed > 0 and distance <= radius + brakeBand then
		correctionSpeed = math.max(correctionSpeed, math.min(inwardSpeed, safetyCap))
	end
	local orbitVelocity = tangent * tangentSpeed + radialDirection * correctionSpeed
	if safetyCap and safetyCap > 0 and orbitVelocity.Magnitude > safetyCap then
		orbitVelocity = orbitVelocity.Unit * safetyCap
	end
	return orbitVelocity
end

local function resolveLocalOrbitState(root, target, activeHookCount, steeringState, _replicatedOrbitState, deltaTime, hookSeparation, accelerationConfig, targetSpeedConfig, safetyCap)
	local closeDualHooks = activeHookCount == 2 and (tonumber(hookSeparation) or math.huge) <= Config.DualOrbitMergeDistance
	local orbitEligibleHookCount = activeHookCount == 1 or closeDualHooks
	if not orbitEligibleHookCount or typeof(target) ~= "Vector3" then
		localOrbitActive = false
		localOrbitTangentialSpeed = 0
		return nil
	end
	local directionValue = steeringState and math.clamp(math.round(tonumber(steeringState.SteeringDirection) or 0), -1, 1) or 0
	if not steeringState or steeringState.SteeringActive ~= true or directionValue == 0 then
		localOrbitActive = false
		localOrbitTangentialSpeed = 0
		return nil
	end
	local offsetFromAnchor = root.Position - target
	local distance = offsetFromAnchor.Magnitude
	if distance <= 0.001 then
		localOrbitActive = false
		localOrbitTangentialSpeed = 0
		return nil
	end
	local targetChanged = not localOrbitActive or (localOrbitAnchor - target).Magnitude > 0.1
	if targetChanged then
		local radialDirection = offsetFromAnchor.Unit
		local radialVelocity = root.AssemblyLinearVelocity:Dot(radialDirection)
		local inwardSpeed = math.max(-radialVelocity, 0)
		local handoffTime = math.max(tonumber(Config.OrbitEntryCompensationTime) or 0, math.min((tonumber(deltaTime) or 0) * 2, 0.1))
		local inwardAcceleration = math.max(tonumber(accelerationConfig) or 0, 0)
		local predictedInwardTravel = inwardSpeed * handoffTime + 0.5 * inwardAcceleration * handoffTime * handoffTime
		local compensation = math.min(predictedInwardTravel, Config.OrbitEntryCompensationMax)
		localOrbitRadius = math.max(distance - compensation, Config.OrbitRadius)
		localOrbitStartTime = os.clock()
		localOrbitAnchor = target
	end
	
	
	localOrbitTangentialSpeed = math.clamp(tonumber(targetSpeedConfig) or localOrbitTangentialSpeed, 0, safetyCap)
	localOrbitActive = true
	localOrbitDirection = directionValue
	return {
		OrbitActive = true,
		OrbitDirection = localOrbitDirection,
		OrbitAnchor = localOrbitAnchor,
		OrbitRadius = localOrbitRadius,
		OrbitStartTime = localOrbitStartTime,
		OrbitTangentialSpeed = localOrbitTangentialSpeed,
		OrbitGeneration = 0,
	}
end

local function getControlledReleaseVelocity(velocity, boostState, activeHookCount)
	if velocity.Magnitude <= 0.001 then
		return velocity, false
	end
	local boostedHookRelease = boostState
		and boostState.BoostActive == true
		and (boostState.BoostMode == "Single" or boostState.BoostMode == "Dual")
	local multiplier = boostedHookRelease and Config.BoostReleaseVelocityMultiplier or Config.MomentumReleaseVelocityMultiplier
	local cap
	local minimumSpeed = 0
	if boostedHookRelease then
		if activeHookCount == 2 then
			cap = Config.DualBoostReleaseMomentumCap
			minimumSpeed = Config.DualBoostReleaseMinimumSpeed
		else
			cap = Config.BoostReleaseMomentumCap
			minimumSpeed = Config.BoostReleaseMinimumSpeed
		end
	else
		cap = Config.MomentumReleaseSpeedCap
	end
	multiplier = tonumber(multiplier) or 0.72
	cap = tonumber(cap) or velocity.Magnitude
	minimumSpeed = tonumber(minimumSpeed) or 0
	local controlledVelocity = velocity * multiplier
	local downwardBias = math.max(tonumber(Config.MomentumDownwardReleaseBias) or 0, 0)
	controlledVelocity += Vector3.new(0, -downwardBias, 0)
	if controlledVelocity.Magnitude > cap then
		controlledVelocity = controlledVelocity.Unit * cap
	end
	if boostedHookRelease and controlledVelocity.Magnitude < minimumSpeed then
		controlledVelocity = controlledVelocity.Unit * math.min(minimumSpeed, cap)
	end
	return controlledVelocity, boostedHookRelease
end

local function prepareReleaseVelocity(currentVelocity, boostState, activeHookCount)
	recordReleaseVelocitySample(currentVelocity)
	local bufferedVelocity = getBufferedReleaseVelocity(currentVelocity)
	local controlledVelocity, boostedHookRelease = getControlledReleaseVelocity(bufferedVelocity, boostState, activeHookCount)
	preparedReleaseVelocity = controlledVelocity
	preparedBoostedRelease = boostedHookRelease == true
end

local function updatePull(deltaTime)
	local character, humanoid, root = getReadyCharacter()
	if not root then
		resetMovementState()
		return
	end
	local grounded, groundNormal = getSlideGroundContact(character, humanoid, root)
	local justLanded = grounded and not previousGrounded
	local currentHorizontalVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	local bufferedLandingVelocity = Vector3.zero
	if not grounded then
		airborneHorizontalFrame2 = airborneHorizontalFrame1
		airborneHorizontalFrame1 = currentHorizontalVelocity
	elseif justLanded then
		bufferedLandingVelocity = airborneHorizontalFrame1.Magnitude >= airborneHorizontalFrame2.Magnitude
			and airborneHorizontalFrame1 or airborneHorizontalFrame2
		airborneHorizontalFrame1 = Vector3.zero
		airborneHorizontalFrame2 = Vector3.zero
	else
		airborneHorizontalFrame1 = Vector3.zero
		airborneHorizontalFrame2 = Vector3.zero
	end
	previousGrounded = grounded
	local target, activeHookCount, _, hookSeparation = resolveApprovedTarget()
	local gasState = stateController and stateController.GetGasState and stateController.GetGasState(localPlayer)
	local gasEmpty = gasState and gasState.GasEmpty == true
	if gasEmpty then
		target = nil
		activeHookCount = 0
	end
	local boostState = stateController and stateController.GetBoostState and stateController.GetBoostState(localPlayer)
	local boostActive = not gasEmpty and boostState and boostState.BoostActive == true
	local replicatedSteeringState = stateController and stateController.GetSteeringState and stateController.GetSteeringState(localPlayer)
	local localSteeringState = inputController and inputController.GetLocalSteeringState and inputController.GetLocalSteeringState()
	local steeringState = localSteeringState and localSteeringState.SteeringActive and localSteeringState or replicatedSteeringState
	local orbitState = stateController and stateController.GetOrbitState and stateController.GetOrbitState(localPlayer)
	local releasedPullThisFrame = previousPulling and not target
	if target and sliding then
		stopLocalSlide()
	end
	if not target then
		if previousPulling then
			movementGeneration += 1
			local wasBoostedHookRelease
			local releaseBoostState = boostState
			if previousBoostActive and (not releaseBoostState or releaseBoostState.BoostActive ~= true) then
				releaseBoostState = {
					BoostActive = true,
					BoostMode = previousBoostMode,
				}
			end
			if preparedReleaseVelocity.Magnitude > 0.001 then
				releaseVelocity = preparedReleaseVelocity
				wasBoostedHookRelease = preparedBoostedRelease
			else
				local bufferedVelocity = getBufferedReleaseVelocity(root.AssemblyLinearVelocity)
				releaseVelocity, wasBoostedHookRelease = getControlledReleaseVelocity(bufferedVelocity, releaseBoostState, previousActiveHookCount)
			end
			root.AssemblyLinearVelocity = releaseVelocity
			momentumDirectionLocked = releaseVelocity.Magnitude > 0.001
			lockedMomentumDirection = momentumDirectionLocked and releaseVelocity.Unit or Vector3.zero
			momentumActive = releaseVelocity.Magnitude >= Config.MomentumMinSpeed
			momentumStartTime = momentumActive and os.clock() or 0
			releaseGeneration = momentumActive and movementGeneration or 0
		end
		previousPulling = false
		local replicatedOrbitActive = orbitState and orbitState.OrbitActive == true
		if sliding and (boostActive or replicatedOrbitActive) then
			stopLocalSlide()
		end
		if not sliding and grounded and not boostActive and not replicatedOrbitActive then
			local horizontalVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
			local entryVelocity = horizontalVelocity
			if justLanded and bufferedLandingVelocity.Magnitude > entryVelocity.Magnitude then
				entryVelocity = bufferedLandingVelocity
			end
			local entryTransition = justLanded or releasedPullThisFrame or momentumActive
			if entryTransition and entryVelocity.Magnitude >= Config.SlideEntryMinSpeed then
				beginLocalSlide(root, groundNormal, entryVelocity)
			end
		end
		if sliding then
			clearMomentumState()
			cleanupOrbitAntiGravity()
			if updateLocalSlide(deltaTime, root, grounded, groundNormal) then
				return
			end
		end
		if momentumActive then
			local elapsed = os.clock() - momentumStartTime
			if elapsed >= Config.MomentumMaxDuration
				or (not (boostActive and boostState.BoostMode == "Momentum") and root.AssemblyLinearVelocity.Magnitude < Config.MomentumMinSpeed)
				or isGroundControlState(humanoid) then
				clearMomentumState()
				cleanupActuator()
				cleanupOrbitAntiGravity()
				return
			end
			local steeringActive = steeringState and steeringState.SteeringActive == true
			local momentumBoosting = boostActive and boostState.BoostMode == "Momentum"
			local steeringAllowed = steeringActive and not momentumDirectionLocked
			if momentumBoosting or steeringAllowed then
				local velocity = root.AssemblyLinearVelocity
				local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
				local direction
				if momentumDirectionLocked and lockedMomentumDirection.Magnitude > 0.001 then
					local lockedHorizontal = Vector3.new(lockedMomentumDirection.X, 0, lockedMomentumDirection.Z)
					direction = lockedHorizontal.Magnitude > 0.001 and lockedHorizontal.Unit or lockedMomentumDirection.Unit
				elseif horizontalVelocity.Magnitude >= Config.MomentumMinSpeed then
					direction = horizontalVelocity.Unit
				else
					local camera = workspace.CurrentCamera
					local fallback = camera and camera.CFrame.LookVector or root.CFrame.LookVector
					local horizontalFallback = Vector3.new(fallback.X, 0, fallback.Z)
					local rootFallback = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
					if horizontalFallback.Magnitude > 0.001 then
						direction = horizontalFallback.Unit
					elseif rootFallback.Magnitude > 0.001 then
						direction = rootFallback.Unit
					else
						direction = Vector3.zAxis
					end
				end
				cleanupOrbitAntiGravity()
				local actuator = ensureActuator(root)
				local safetyCap = momentumBoosting and Config.MomentumBoostSafetySpeedCap or Config.MomentumSafetySpeedCap
				local targetSpeed = momentumBoosting and math.min(Config.MomentumBoostTargetSpeed, safetyCap) or math.min(horizontalVelocity.Magnitude, safetyCap)
				local baseVelocity = direction * targetSpeed
				local steeredVelocity = momentumDirectionLocked and baseVelocity or applySteering(baseVelocity, root, steeringState, false, momentumBoosting, true, safetyCap)
				local acceleration = momentumBoosting and Config.MomentumBoostAcceleration or Config.AirSteerAcceleration
				local horizontalForce = math.max(root.AssemblyMass * acceleration, 1)
				actuator.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				actuator.MaxAxesForce = Vector3.new(horizontalForce, 0, horizontalForce)
				actuator.VectorVelocity = Vector3.new(steeredVelocity.X, 0, steeredVelocity.Z)
				return
			end
		end
		cleanupActuator()
		cleanupOrbitAntiGravity()
		return
	end
	if not previousPulling then
		movementGeneration += 1
		clearReleaseDirectionBuffer()
	end
	previousPulling = true
	previousActiveHookCount = activeHookCount
	previousBoostActive = boostActive == true
	previousBoostMode = boostState and boostState.BoostMode or "None"
	prepareReleaseVelocity(root.AssemblyLinearVelocity, boostState, activeHookCount)
	if momentumActive then
		clearMomentumState()
	end
	local isDualHook = activeHookCount == 2
	local targetSpeedConfig = isDualHook and Config.DualHookTargetSpeed or Config.PullTargetSpeed
	local accelerationConfig = isDualHook and Config.DualHookAcceleration or Config.PullAcceleration
	local safetyCap = isDualHook and Config.DualHookSafetySpeedCap or Config.PullSafetySpeedCap
	if boostActive and isDualHook then
		targetSpeedConfig = Config.DualBoostTargetSpeed
		accelerationConfig = Config.DualBoostAcceleration
		safetyCap = Config.DualBoostSafetySpeedCap
	elseif boostActive then
		targetSpeedConfig = Config.BoostTargetSpeed
		accelerationConfig = Config.BoostAcceleration
		safetyCap = Config.BoostSafetySpeedCap
	end
	local closeDualHooks = isDualHook and (tonumber(hookSeparation) or math.huge) <= Config.DualOrbitMergeDistance
	if grounded then
		localOrbitActive = false
		localOrbitTangentialSpeed = 0
	end
	if not grounded and (not isDualHook or closeDualHooks) then
		local effectiveOrbitState = resolveLocalOrbitState(root, target, activeHookCount, steeringState, orbitState, deltaTime, hookSeparation, accelerationConfig, targetSpeedConfig, safetyCap)
		local orbitVelocity = computeOrbitVelocity(root, effectiveOrbitState, boostActive, safetyCap)
		if orbitVelocity then
			ensureOrbitAntiGravity(root)
			local actuator = ensureActuator(root)
			local orbitForce = math.max(root.AssemblyMass * Config.OrbitRadialCorrectionStrength, root.AssemblyMass * accelerationConfig, 1)
			actuator.ForceLimitMode = Enum.ForceLimitMode.Magnitude
			actuator.MaxForce = orbitForce
			actuator.VectorVelocity = orbitVelocity
			return
		end
	end
	cleanupOrbitAntiGravity()
	local slowdownRadius = isDualHook and Config.DualHookSlowdownRadius or Config.PullSlowdownRadius
	local minimumDistance = isDualHook and Config.DualHookMinimumDistance or Config.PullMinimumDistance
	local offset = target - root.Position
	local distance = offset.Magnitude
	if distance <= minimumDistance or distance <= 0.001 then
		cleanupActuator()
		return
	end
	local speedScale = 1
	if distance < slowdownRadius then
		local slowdownSpan = math.max(slowdownRadius - minimumDistance, 0.001)
		speedScale = math.clamp((distance - minimumDistance) / slowdownSpan, 0, 1)
	end
	local targetSpeed = math.min(targetSpeedConfig * speedScale, safetyCap)
	local actuator = ensureActuator(root)
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	
	
	
	if grounded then
		groundLaunchUntil = math.max(groundLaunchUntil, os.clock() + Config.GroundPullLaunchDuration)
		local state = humanoid:GetState()
		if state == Enum.HumanoidStateType.Running
			or state == Enum.HumanoidStateType.RunningNoPhysics
			or state == Enum.HumanoidStateType.Landed
			or state == Enum.HumanoidStateType.GettingUp then
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end
	local launchAssisted = os.clock() < groundLaunchUntil
	local pullVelocity = offset.Unit * targetSpeed
	if launchAssisted and pullVelocity.Y < Config.GroundPullLaunchUpSpeed then
		pullVelocity = Vector3.new(pullVelocity.X, Config.GroundPullLaunchUpSpeed, pullVelocity.Z)
		if pullVelocity.Magnitude > safetyCap then
			pullVelocity = pullVelocity.Unit * safetyCap
		end
	end
	local steeringApplied
	pullVelocity, steeringApplied = applySteering(pullVelocity, root, steeringState, isDualHook, boostActive, false, safetyCap)
	local forceMultiplier = launchAssisted and Config.GroundPullLaunchForceMultiplier or 1
	local horizontalForce = math.max(root.AssemblyMass * accelerationConfig * forceMultiplier, 1)
	if steeringApplied then
		horizontalForce = math.max(horizontalForce, root.AssemblyMass * Config.AirSteerAcceleration)
	end
	if boostActive then
		local verticalForce = math.max(root.AssemblyMass * Config.PullAcceleration * forceMultiplier, 1)
		actuator.ForceLimitMode = Enum.ForceLimitMode.PerAxis
		actuator.MaxAxesForce = Vector3.new(horizontalForce, verticalForce, horizontalForce)
	else
		actuator.ForceLimitMode = Enum.ForceLimitMode.Magnitude
		actuator.MaxForce = horizontalForce
	end
	actuator.VectorVelocity = pullVelocity
end

function ODMGMovementController.GetSlideState()
	return {
		Sliding = sliding,
		SlideStartTime = slideStartTime,
		SlideStartSpeed = slideSpeed,
		SlideDirection = slideDirection,
	}
end

function ODMGMovementController.GetMomentumState()
	return {
		MomentumActive = momentumActive,
		ReleaseVelocity = releaseVelocity,
		MomentumStartTime = momentumStartTime,
		PreviousPulling = previousPulling,
		Generation = movementGeneration,
		ReleaseGeneration = releaseGeneration,
	}
end

function ODMGMovementController.Init(controllers)
	stateController = controllers and controllers.ODMGStateController
	inputController = controllers and controllers.ODMGInputController
	if not stateController then
		warn("[ODMG Movement] ODMGStateController dependency is missing")
	end
end

function ODMGMovementController.Start()
	if started then return end
	started = true
	localPlayer.CharacterRemoving:Connect(function()
		resetMovementState()
		if stateController and stateController.ClearPlayerState then
			stateController.ClearPlayerState(localPlayer)
		end
	end)
	localPlayer.CharacterAdded:Connect(function()
		resetMovementState()
	end)
	heartbeatConnection = RunService.Heartbeat:Connect(updatePull)
end

return ODMGMovementController
