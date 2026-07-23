local ServerStorage = game:GetService("ServerStorage")

local Config = require(script.Parent:WaitForChild("ODMGAttachmentConfig"))

local ODMGAttachmentService = {}
local activeConnections = setmetatable({}, { __mode = "k" })

local function warnMissing(message)
	warn(string.format("[ODMGAttachmentService] %s", message))
end

local function findByPath(root, path)
	local current = root
	for _, name in ipairs(path) do
		current = current and current:FindFirstChild(name)
	end
	return current
end

local function getTemplate()
	local assets = ServerStorage:FindFirstChild(Config.TemplateFolderName)
	return assets and assets:FindFirstChild(Config.TemplateName)
end

local function disconnectCharacter(character)
	local connections = activeConnections[character]
	if not connections then
		return
	end

	activeConnections[character] = nil
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
end

local function destroyManagedJoints(character)
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:GetAttribute(Config.ManagedAttribute) then
			descendant:Destroy()
		end
	end
end

local function prepareParts(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
end

local function ensureCableOrigins(equipment)
	local definitions = {
		Left = { PartName = "LeftGrappleBox", AttachmentName = "CableOrigin_Left" },
		Right = { PartName = "RightGrappleBox", AttachmentName = "CableOrigin_Right" },
	}
	for sideName, definition in pairs(definitions) do
		local side = equipment:FindFirstChild(sideName)
		local grappleBox = side and side:FindFirstChild(definition.PartName)
		if grappleBox and grappleBox:IsA("BasePart") then
			local attachment = grappleBox:FindFirstChild(definition.AttachmentName)
			if not attachment then
				attachment = Instance.new("Attachment")
				attachment.Name = definition.AttachmentName
				attachment.CFrame = CFrame.identity
				attachment.Parent = grappleBox
			end
		end
	end
end

local function createManagedWeld(parent, name, part0, part1)
	local weld = Instance.new("WeldConstraint")
	weld.Name = name
	weld.Part0 = part0
	weld.Part1 = part1
	weld:SetAttribute(Config.ManagedAttribute, true)
	weld.Parent = parent
	return weld
end

local function createManagedMotor(parent, name, part0, part1, offset)
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = offset
	motor.C1 = CFrame.identity
	motor:SetAttribute(Config.ManagedAttribute, true)
	motor.Parent = parent
	return motor
end

local function attachStaticEquipment(equippedFolder, equipment, torso)
	for _, definition in ipairs(Config.StaticEquipment) do
		local part = findByPath(equipment, definition.Path)
		if not part or not part:IsA("BasePart") then
			warnMissing(string.format("Static equipment part '%s' is missing; continuing without it.", table.concat(definition.Path, ".")))
			continue
		end

		part.CFrame = torso.CFrame * definition.Offset
		createManagedWeld(equippedFolder, definition.JointName, torso, part)
	end
end

local function attachHandEquipment(equippedFolder, equipment, character, sideName, definition)
	local sideModel = equipment:FindFirstChild(definition.SideModel)
	local limb = character:FindFirstChild(Config.R6Parts[definition.LimbKey])
	if not sideModel then
		warnMissing(string.format("%s equipment model is missing; continuing without that hand setup.", sideName))
		return
	end
	if not limb or not limb:IsA("BasePart") then
		warnMissing(string.format("R6 limb '%s' is missing; continuing without the %s handle.", Config.R6Parts[definition.LimbKey], sideName))
		return
	end

	local driver = sideModel:FindFirstChild(definition.DriverName)
	if not driver or not driver:IsA("BasePart") then
		warnMissing(string.format("%s driver '%s' is missing; continuing without that handle.", sideName, definition.DriverName))
		return
	end

	driver.CFrame = limb.CFrame * definition.HandleOffset

	createManagedMotor(limb, definition.MotorName, limb, driver, definition.HandleOffset)

	local blade = sideModel:FindFirstChild(definition.BladeName)
	if not blade or not blade:IsA("BasePart") then
		warnMissing(string.format("%s blade is missing; the handle was still attached.", sideName))
		return
	end

	blade.CFrame = driver.CFrame * definition.BladeOffset
	createManagedMotor(driver, definition.BladeMotorName, driver, blade, definition.BladeOffset)
end

function ODMGAttachmentService.GetODMGFolder(character)
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return nil
	end
	return character:FindFirstChild(Config.EquippedFolderName)
end

function ODMGAttachmentService.HasODMG(character)
	return ODMGAttachmentService.GetODMGFolder(character) ~= nil
end

function ODMGAttachmentService.RemoveODMG(character)
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return false
	end

	disconnectCharacter(character)
	local equippedFolder = ODMGAttachmentService.GetODMGFolder(character)
	local hadEquipment = equippedFolder ~= nil

	destroyManagedJoints(character)
	if equippedFolder then
		equippedFolder:Destroy()
	end
	character:SetAttribute(Config.EquippedAttribute, nil)
	return hadEquipment
end

function ODMGAttachmentService.AttachODMG(character)
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		warnMissing("AttachODMG expected a character Model.")
		return nil
	end

	ODMGAttachmentService.RemoveODMG(character)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warnMissing(string.format("Character '%s' has no Humanoid.", character.Name))
		return nil
	end
	if humanoid.RigType ~= Enum.HumanoidRigType.R6 then
		warnMissing(string.format("Character '%s' is %s; this reference equipment is authored for R6.", character.Name, humanoid.RigType.Name))
		return nil
	end

	local torso = character:FindFirstChild(Config.R6Parts.Torso)
	local leftArm = character:FindFirstChild(Config.R6Parts.LeftArm)
	local rightArm = character:FindFirstChild(Config.R6Parts.RightArm)
	if not torso or not torso:IsA("BasePart") then
		warnMissing(string.format("Character '%s' is missing its R6 Torso.", character.Name))
		return nil
	end
	if not leftArm or not rightArm then
		warnMissing(string.format("Character '%s' is missing one or both R6 arms.", character.Name))
		return nil
	end
	if leftArm:FindFirstChild(Config.HandEquipment.Left.MotorName) or rightArm:FindFirstChild(Config.HandEquipment.Right.MotorName) then
		warnMissing(string.format("Character '%s' already has a non-ODMG HandleL or HandleR joint; attachment was cancelled to avoid animation conflicts.", character.Name))
		return nil
	end

	local template = getTemplate()
	if not template then
		warnMissing(string.format("Missing ServerStorage.%s.%s template.", Config.TemplateFolderName, Config.TemplateName))
		return nil
	end

	local equippedFolder = Instance.new("Folder")
	equippedFolder.Name = Config.EquippedFolderName
	equippedFolder.Parent = character

	local equipment = template:Clone()
	equipment.Name = Config.EquipmentModelName
	equipment.Parent = equippedFolder
	prepareParts(equipment)
	ensureCableOrigins(equipment)

	attachStaticEquipment(equippedFolder, equipment, torso)
	attachHandEquipment(equippedFolder, equipment, character, "Left", Config.HandEquipment.Left)
	attachHandEquipment(equippedFolder, equipment, character, "Right", Config.HandEquipment.Right)

	character:SetAttribute(Config.EquippedAttribute, true)
	activeConnections[character] = {
		humanoid.Died:Connect(function()
			ODMGAttachmentService.RemoveODMG(character)
		end),
		character.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				ODMGAttachmentService.RemoveODMG(character)
			end
		end),
	}

	return equippedFolder
end

return ODMGAttachmentService
