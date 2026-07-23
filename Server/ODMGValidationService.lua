local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ODMG = ReplicatedStorage:WaitForChild("ODMG")
local Config = require(ODMG:WaitForChild("Config"):WaitForChild("ODMGConfig"))
local Util = require(ODMG:WaitForChild("SharedModules"):WaitForChild("ODMGUtil"))
local Remotes = ODMG:WaitForChild("Remotes")

local ODMGValidationService = {}
local stateService
local started = false
local requestState = setmetatable({}, { __mode = "k" })
local failureStats = {}

local requestRemotes = { Left = Remotes:WaitForChild("RequestLeftHook"), Right = Remotes:WaitForChild("RequestRightHook") }
local releaseRemotes = { Left = Remotes:WaitForChild("ReleaseLeftHook"), Right = Remotes:WaitForChild("ReleaseRightHook") }
local replicateHookState = Remotes:WaitForChild("ReplicateHookState")

local function debugLog(player, sideName, sequence, formatString, ...)
	if Config.DebugGrapples then
		print(string.format(
			"[ODMG Server %.3f] player=%s side=%s seq=%s " .. formatString,
			os.clock(), player and player.Name or "nil", sideName or "nil", tostring(sequence or 0), ...
		))
	end
end

local function getSideRequestState(player, sideName)
	local playerState = requestState[player]
	if not playerState then
		playerState = {
			Left = { LatestSequence = 0, ReleasedSequence = 0, ActiveSequence = 0 },
			Right = { LatestSequence = 0, ReleasedSequence = 0, ActiveSequence = 0 },
		}
		requestState[player] = playerState
	end
	return playerState[sideName]
end

local function recordFailure(player, sideName, code, detail, diagnosticResult)
	code = code or "UnknownFailure"
	failureStats[code] = (failureStats[code] or 0) + 1
	local hitDescription = "nil"
	if diagnosticResult then
		hitDescription = string.format("%s at %s", diagnosticResult.Instance:GetFullName(), tostring(diagnosticResult.Position))
	end
	local sequence = 0
	local playerRequestState = player and requestState[player]
	local sideRequestState = playerRequestState and playerRequestState[sideName]
	if sideRequestState then sequence = sideRequestState.LatestSequence end
	if Config.DebugGrapples then
		warn(string.format(
			"[ODMG Server %.3f] player=%s side=%s seq=%d event=Rejected reason=%s detail=%s observedHit=%s count=%d",
			os.clock(), player and player.Name or "nil", sideName or "nil", sequence, code, tostring(detail), hitDescription, failureStats[code]
		))
	end
	return false, code
end

local function replicate(player, sideName, active, hitPosition, sequence)
	local ok, err = pcall(replicateHookState.FireAllClients, replicateHookState, player, sideName, active, hitPosition, sequence)
	if not ok then
		return recordFailure(player, sideName, "ReplicationFailure", err)
	end
	debugLog(player, sideName, sequence, "event=ReplicationSent active=%s", tostring(active))
	return true
end

local function validatePlayerState(player, sideName)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil, "UnknownFailure", "Invalid Player instance"
	end
	local character = player.Character
	if not character or not character:IsDescendantOf(workspace) then
		return nil, "CharacterInactive", "Character is unavailable or outside Workspace"
	end
	if not stateService or not stateService.IsEquipped(player) then
		return nil, "CharacterNotEquipped", "Authoritative player ODMG state is false"
	end
	if not stateService.GetCharacterState(character) then
		return nil, "CharacterInactive", "ODMG character state folder is missing"
	end
	local originAttachment, originPart = Util.GetHookOrigin(character, sideName)
	if not originPart then
		return nil, "MissingOrigin", "Grapple origin part is missing"
	end
	if not originAttachment then
		return nil, "MissingAttachment", "Cable-origin attachment is missing"
	end
	return character
end

local function validSequence(value)
	return type(value) == "number" and value == value and value >= 1 and value % 1 == 0
end

function ODMGValidationService.RequestHook(player, sideName, aimData)
	if sideName ~= "Left" and sideName ~= "Right" then
		return recordFailure(player, sideName, "UnknownFailure", "Invalid hook side")
	end
	if type(aimData) ~= "table" or not validSequence(aimData.Sequence) then
		return recordFailure(player, sideName, "InvalidTarget", "Aim payload or sequence is invalid")
	end
	local sideRequests = getSideRequestState(player, sideName)
	local sequence = aimData.Sequence
	debugLog(player, sideName, sequence, "event=RequestReceived")
	if sequence <= sideRequests.ReleasedSequence then
		return recordFailure(player, sideName, "StateConflict", "Request arrived after its release")
	end
	if sequence < sideRequests.LatestSequence then
		return recordFailure(player, sideName, "StateConflict", "Stale request sequence")
	end
	sideRequests.LatestSequence = sequence

	local character, stateCode, stateDetail = validatePlayerState(player, sideName)
	if not character then
		return recordFailure(player, sideName, stateCode, stateDetail)
	end
	local valid, resultOrCode, detail, diagnosticResult = Util.ValidateHookTarget(character, sideName, aimData)
	if not valid then
		return recordFailure(player, sideName, resultOrCode, detail, diagnosticResult)
	end
	local result = resultOrCode
	if not stateService.SetHookState(character, sideName, true, result.Position, result.Instance) then
		return recordFailure(player, sideName, "StateConflict", "Hook state container rejected the update", result)
	end
	sideRequests.ActiveSequence = sequence
	local replicated = replicate(player, sideName, true, result.Position, sequence)
	if not replicated then
		stateService.ClearHookState(character, sideName)
		return false, "ReplicationFailure"
	end
	debugLog(player, sideName, sequence,
		"event=Approved hitPart=%s confirmedPart=%s aimHit=%s confirmedHit=%s difference=%.3f distance=%.2f",
		result.Instance:GetFullName(), result.ConfirmedPart:GetFullName(),
		tostring(result.AimHitPosition), tostring(result.ConfirmedHitPosition), result.DifferenceMagnitude,
		(Util.GetHookOrigin(character, sideName).WorldPosition - result.AimHitPosition).Magnitude)
	return true, result
end

function ODMGValidationService.ReleaseHook(player, sideName, sequence)
	if sideName ~= "Left" and sideName ~= "Right" then
		return recordFailure(player, sideName, "UnknownFailure", "Invalid release side")
	end
	local sideRequests = getSideRequestState(player, sideName)
	debugLog(player, sideName, sequence, "event=ReleaseReceived")
	if validSequence(sequence) then
		sideRequests.ReleasedSequence = math.max(sideRequests.ReleasedSequence, sequence)
	else
		sequence = sideRequests.LatestSequence
	end
	if sideRequests.ActiveSequence > sequence then
		return true
	end
	local character = player and player.Character
	if character and stateService then
		stateService.ClearHookState(character, sideName)
	end
	sideRequests.ActiveSequence = 0
	replicate(player, sideName, false, Vector3.zero, sequence)
	debugLog(player, sideName, sequence, "event=ReleaseProcessed")
	return true
end

function ODMGValidationService.ClearPlayerHooks(player, character)
	if stateService and character then
		stateService.ClearAllHookStates(character)
	end
	for _, sideName in ipairs({ "Left", "Right" }) do
		replicate(player, sideName, false, Vector3.zero, 0)
	end
	requestState[player] = nil
end

function ODMGValidationService.InvalidateHook(player, sideName, reason)
	if sideName ~= "Left" and sideName ~= "Right" then
		return false
	end
	local character = player and player.Character
	local sideRequests = getSideRequestState(player, sideName)
	local sequence = math.max(sideRequests.ActiveSequence, sideRequests.LatestSequence)
	if character and stateService then
		stateService.ClearHookState(character, sideName)
	end
	sideRequests.ActiveSequence = 0
	sideRequests.ReleasedSequence = math.max(sideRequests.ReleasedSequence, sequence)
	replicate(player, sideName, false, Vector3.zero, sequence)
	debugLog(player, sideName, sequence, "event=Invalidated reason=%s", tostring(reason or "InvalidTarget"))
	return true
end

function ODMGValidationService.GetFailureStats()
	return table.clone(failureStats)
end

function ODMGValidationService.Init(services)
	stateService = services and services.ODMGStateService
	if not stateService then
		warn("[ODMG Validation] ODMGStateService dependency is missing")
		return
	end
	stateService.RegisterCleanupHandler("Grapples", function(player, character)
		ODMGValidationService.ClearPlayerHooks(player, character)
	end)
end

function ODMGValidationService.Start()
	if started then
		return
	end
	started = true
	for sideName, remote in pairs(requestRemotes) do
		remote.OnServerEvent:Connect(function(player, aimData)
			local ok, err = xpcall(ODMGValidationService.RequestHook, debug.traceback, player, sideName, aimData)
			if not ok then
				recordFailure(player, sideName, "UnknownFailure", err)
			end
		end)
	end
	for sideName, remote in pairs(releaseRemotes) do
		remote.OnServerEvent:Connect(function(player, sequence)
			local ok, err = xpcall(ODMGValidationService.ReleaseHook, debug.traceback, player, sideName, sequence)
			if not ok then
				recordFailure(player, sideName, "UnknownFailure", err)
			end
		end)
	end
end

return ODMGValidationService
