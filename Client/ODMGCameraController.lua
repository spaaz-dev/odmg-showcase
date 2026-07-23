local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("ODMG"):WaitForChild("Config"):WaitForChild("ODMGConfig"))

local ODMGCameraController = {}
local stateController
local started = false
local active = false
local RENDER_STEP_NAME = "ODMGShiftStyleFreeCursorCamera"
local previousMouseBehavior
local previousMouseIconEnabled
local previousCameraType
local previousCameraSubject
local previousCameraOffset
local previousAutoRotate

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

local function restoreCamera()
	if not active then
		return
	end
	active = false
	local camera = workspace.CurrentCamera
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if camera then
		camera.CameraType = previousCameraType or Enum.CameraType.Custom
		camera.CameraSubject = previousCameraSubject or humanoid
	end
	if humanoid then
		humanoid.CameraOffset = previousCameraOffset or Vector3.zero
		if previousAutoRotate ~= nil then
			humanoid.AutoRotate = previousAutoRotate
		else
			humanoid.AutoRotate = true
		end
	end
	UserInputService.MouseBehavior = previousMouseBehavior or Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = previousMouseIconEnabled ~= nil and previousMouseIconEnabled or true
	previousMouseBehavior = nil
	previousMouseIconEnabled = nil
	previousCameraType = nil
	previousCameraSubject = nil
	previousCameraOffset = nil
	previousAutoRotate = nil
end

local function beginCamera(camera, humanoid)
	if active then
		return
	end
	active = true
	previousCameraType = camera.CameraType
	previousCameraSubject = camera.CameraSubject
	previousMouseBehavior = UserInputService.MouseBehavior
	previousMouseIconEnabled = UserInputService.MouseIconEnabled
	previousCameraOffset = humanoid.CameraOffset
	previousAutoRotate = humanoid.AutoRotate
end

local function getActiveHookFaceTarget()
	if not stateController then
		return nil
	end
	local left = stateController.GetHookState(localPlayer, "Left")
	local right = stateController.GetHookState(localPlayer, "Right")
	local leftActive = left and left.Active == true and typeof(left.HitPosition) == "Vector3"
	local rightActive = right and right.Active == true and typeof(right.HitPosition) == "Vector3"
	if leftActive and rightActive then
		return (left.HitPosition + right.HitPosition) / 2
	elseif leftActive then
		return left.HitPosition
	elseif rightActive then
		return right.HitPosition
	end
	return nil
end

local function faceRootToward(root, worldPosition)
	local offset = worldPosition - root.Position
	local flatOffset = Vector3.new(offset.X, 0, offset.Z)
	if flatOffset.Magnitude <= 0.001 then
		return false
	end
	local linearVelocity = root.AssemblyLinearVelocity
	local angularVelocity = root.AssemblyAngularVelocity
	root.CFrame = CFrame.lookAt(root.Position, root.Position + flatOffset.Unit)
	root.AssemblyLinearVelocity = linearVelocity
	root.AssemblyAngularVelocity = angularVelocity
	return true
end

local function applyCamera()
	if Config.CustomCameraEnabled ~= true then
		restoreCamera()
		local _, _, root = getReadyCharacter()
		local hookFaceTarget = root and getActiveHookFaceTarget()
		if hookFaceTarget then
			faceRootToward(root, hookFaceTarget)
		end
		return
	end
	local camera = workspace.CurrentCamera
	local _, humanoid, root = getReadyCharacter()
	if not camera or not humanoid or not root then
		restoreCamera()
		return
	end
	beginCamera(camera, humanoid)

	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid
	UserInputService.MouseIconEnabled = true

	local offsetX = tonumber(Config.ShiftStyleCameraOffsetX) or 0
	local offsetY = tonumber(Config.ShiftStyleCameraOffsetY) or 0
	local offsetZ = tonumber(Config.ShiftStyleCameraOffsetZ) or 0
	humanoid.CameraOffset = Vector3.new(offsetX, offsetY, offsetZ)
	humanoid.AutoRotate = false

	local hookFaceTarget = getActiveHookFaceTarget()
	if hookFaceTarget then
		faceRootToward(root, hookFaceTarget)
		return
	end

	local rightMouseHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	local shouldFaceCamera = rightMouseHeld or humanoid.MoveDirection.Magnitude > 0.001 or root.AssemblyLinearVelocity.Magnitude > 1
	if shouldFaceCamera then
		local look = camera.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		if flatLook.Magnitude > 0.001 then
			faceRootToward(root, root.Position + flatLook.Unit)
		end
	end
end

function ODMGCameraController.Init(controllers)
	stateController = controllers and controllers.ODMGStateController
end

function ODMGCameraController.Start()
	if started then return end
	started = true
	localPlayer.CharacterRemoving:Connect(restoreCamera)
	localPlayer.CharacterAdded:Connect(function()
		restoreCamera()
	end)
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, applyCamera)
end

return ODMGCameraController
