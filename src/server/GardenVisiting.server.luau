-- GardenVisiting: Cross-server garden visiting, read-only viewing, and rating.
-- Uses MessagingService to locate players across servers,
-- TeleportService to move visitors to the host's server,
-- and DataStore to load gardens of offline players.
--
-- Flow:
--   1. Visitor searches for a garden (friends, random, or by name)
--   2. Server resolves the target: same server, other server, or offline
--   3a. Same server → enter visitor mode locally
--   3b. Other server → TeleportService to that server with visit data
--   3c. Offline → load garden snapshot from DataStore
--   4. Visitor views garden in read-only mode
--   5. Visitor rates the garden (1-5 stars)
--   6. Visitor returns to own garden

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local TeleportService = game:GetService("TeleportService")
local MessagingService = game:GetService("MessagingService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local GameConfig = require(Shared.Config.GameConfig)
local DataManager = require(script.Parent.DataManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local PLACE_ID = game.PlaceId
local SERVER_ID = game.JobId

local RATING_COOLDOWN = 60          -- seconds between ratings for the same garden
local VISIT_COIN_REWARD = 5         -- coins given to owner per visit
local MAX_RATING_HISTORY = 200      -- max ratings stored per player
local SERVER_HEARTBEAT_INTERVAL = 30 -- seconds between presence broadcasts
local PRESENCE_TTL = 60             -- seconds before a server presence expires
local SEARCH_RESULT_LIMIT = 20

-- DataStore for garden snapshots and ratings (separate from player data)
local GardenStore = DataStoreService:GetOrderedDataStore("BloomIsland_GardenRatings_v1")
local PlayerDataStore = DataStoreService:GetDataStore("BloomIsland_v1")

-- MessagingService topic for server presence
local PRESENCE_TOPIC = "BloomIsland_ServerPresence"
local VISIT_REQUEST_TOPIC = "BloomIsland_VisitRequest"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getOrCreateRemote(className: string, name: string): Instance
	local remote = Remotes:FindFirstChild(name)
	if not remote then
		remote = Instance.new(className)
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end

-- Remotes
local RE_VisitGarden = getOrCreateRemote("RemoteEvent", "RE_VisitGarden")
local RE_LeaveGarden = getOrCreateRemote("RemoteEvent", "RE_LeaveGarden")
local RE_RateGarden = getOrCreateRemote("RemoteEvent", "RE_RateGarden")
local RE_VisitStarted = getOrCreateRemote("RemoteEvent", "RE_VisitStarted")
local RE_VisitEnded = getOrCreateRemote("RemoteEvent", "RE_VisitEnded")
local RE_RateResult = getOrCreateRemote("RemoteEvent", "RE_RateResult")
local RE_VisitFailed = getOrCreateRemote("RemoteEvent", "RE_VisitFailed")
local RF_SearchGardens = getOrCreateRemote("RemoteFunction", "RF_SearchGardens")
local RF_GetGardenView = getOrCreateRemote("RemoteFunction", "RF_GetGardenView")

local function getPlayerData(player: Player)
	return DataManager.getData(player.UserId)
end

--------------------------------------------------------------------------------
-- Visitor State
--------------------------------------------------------------------------------

-- UserId -> { targetUserId, gardenData, enteredAt, isOfflineGarden }
type VisitState = {
	targetUserId: number,
	targetName: string,
	gardenData: any,        -- snapshot of plots, creatures, rating, etc.
	enteredAt: number,
	isOfflineGarden: boolean,
}

local activeVisits: { [number]: VisitState } = {}

-- UserId -> last rating timestamp per target: { [targetUserId] = timestamp }
local ratingCooldowns: { [number]: { [number]: number } } = {}

-- Players arriving via TeleportService with visit intent
-- Checked on PlayerAdded to auto-enter visitor mode
local pendingVisitArrivals: { [number]: number } = {} -- visitorUserId -> targetUserId

local function isVisiting(userId: number): boolean
	return activeVisits[userId] ~= nil
end

--------------------------------------------------------------------------------
-- Server Presence (MessagingService)
-- Each server periodically broadcasts which players are on it.
-- Other servers cache this to locate players for cross-server visits.
--------------------------------------------------------------------------------

-- Cache of known player locations: userId -> { serverId, playerName, lastSeen }
local playerPresence: { [number]: { serverId: string, playerName: string, lastSeen: number } } = {}

local function broadcastPresence()
	local playerList = {}
	for _, player in Players:GetPlayers() do
		-- Don't broadcast visitors as "here" for their own garden
		if not isVisiting(player.UserId) then
			table.insert(playerList, {
				userId = player.UserId,
				name = player.Name,
			})
		end
	end

	if #playerList == 0 then return end

	pcall(function()
		MessagingService:PublishAsync(PRESENCE_TOPIC, {
			serverId = SERVER_ID,
			players = playerList,
			timestamp = os.time(),
		})
	end)
end

-- Listen for presence from other servers
pcall(function()
	MessagingService:SubscribeAsync(PRESENCE_TOPIC, function(message)
		local data = message.Data
		if not data or not data.players then return end

		for _, entry in data.players do
			playerPresence[entry.userId] = {
				serverId = data.serverId,
				playerName = entry.name,
				lastSeen = data.timestamp,
			}
		end
	end)
end)

-- Periodic presence heartbeat
task.spawn(function()
	while true do
		broadcastPresence()
		task.wait(SERVER_HEARTBEAT_INTERVAL)
	end
end)

-- Prune stale presence entries
task.spawn(function()
	while true do
		task.wait(PRESENCE_TTL)
		local now = os.time()
		for userId, info in playerPresence do
			if now - info.lastSeen > PRESENCE_TTL then
				playerPresence[userId] = nil
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Garden Data Loading
--------------------------------------------------------------------------------

-- Build a garden snapshot from player data (for viewing)
local function buildGardenSnapshot(data, ownerUserId: number, ownerName: string)
	local plantDetails = {}
	for plotIndex, plot in data.plots do
		if plot and plot.seedId then
			local plantInfo = PlantData[plot.seedId]
			plantDetails[plotIndex] = {
				seedId = plot.seedId,
				name = plantInfo and plantInfo.name or plot.seedId,
				tier = plantInfo and plantInfo.tier or "Common",
				growthProgress = plot.growthProgress or 0,
				mutation = plot.mutation,
			}
		end
	end

	return {
		ownerUserId = ownerUserId,
		ownerName = ownerName,
		plots = plantDetails,
		maxPlots = data.maxPlots or GameConfig.MAX_PLOTS_BASE,
		gardenRating = data.social and data.social.gardenRating or 0,
		visitCount = data.social and data.social.visitCount or 0,
		totalHarvests = data.stats and data.stats.totalHarvests or 0,
		rareFinds = data.stats and data.stats.rareFinds or 0,
		creatureCount = data.creatures and #data.creatures or 0,
	}
end

-- Load garden data for an offline player from DataStore
local function loadOfflineGarden(targetUserId: number): (any?, string?)
	local key = `Player_{targetUserId}`
	local success, data = pcall(function()
		return PlayerDataStore:GetAsync(key)
	end)

	if not success or not data then
		return nil, "GARDEN_NOT_FOUND"
	end

	return data, nil
end

-- Get display name for a userId (best-effort)
local function getPlayerName(userId: number): string
	-- Check if online on this server
	local player = Players:GetPlayerByUserId(userId)
	if player then return player.Name end

	-- Check presence cache
	local presence = playerPresence[userId]
	if presence then return presence.playerName end

	-- Fallback to Roblox API
	local success, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if success and name then return name end

	return `Player_{userId}`
end

--------------------------------------------------------------------------------
-- Visit Initiation
--------------------------------------------------------------------------------

RE_VisitGarden.OnServerEvent:Connect(function(player: Player, targetUserId)
	-- Validate
	if typeof(targetUserId) ~= "number" then return end
	if targetUserId == player.UserId then return end

	-- Can't visit while already visiting
	if isVisiting(player.UserId) then
		RE_VisitFailed:FireClient(player, "ALREADY_VISITING")
		return
	end

	local targetName = getPlayerName(targetUserId)

	-- Check if target is on the same server
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if targetPlayer then
		-- Same server — load their live data
		local targetData = getPlayerData(targetPlayer)
		local snapshot = buildGardenSnapshot(targetData, targetUserId, targetPlayer.Name)

		-- Increment visit count on owner
		targetData.social.visitCount += 1
		targetData.coins += VISIT_COIN_REWARD

		activeVisits[player.UserId] = {
			targetUserId = targetUserId,
			targetName = targetPlayer.Name,
			gardenData = snapshot,
			enteredAt = os.time(),
			isOfflineGarden = false,
		}

		RE_VisitStarted:FireClient(player, snapshot)
		return
	end

	-- Check if target is on another server via presence
	local presence = playerPresence[targetUserId]
	if presence and presence.serverId ~= SERVER_ID then
		-- Cross-server teleport
		local teleportData = {
			visitTargetUserId = targetUserId,
			returnServerId = SERVER_ID,
		}

		local teleportOptions = Instance.new("TeleportOptions")
		teleportOptions.ServerInstanceId = presence.serverId
		teleportOptions:SetTeleportData(teleportData)

		local success, err = pcall(function()
			TeleportService:TeleportAsync(PLACE_ID, { player }, teleportOptions)
		end)

		if not success then
			warn(`Teleport failed for {player.Name}: {err}`)
			RE_VisitFailed:FireClient(player, "TELEPORT_FAILED")
		end
		-- Player will leave this server; arrival handled on the other server
		return
	end

	-- Target is offline or not found in presence — load from DataStore
	local offlineData, loadErr = loadOfflineGarden(targetUserId)
	if not offlineData then
		RE_VisitFailed:FireClient(player, loadErr or "GARDEN_NOT_FOUND")
		return
	end

	local snapshot = buildGardenSnapshot(offlineData, targetUserId, targetName)

	-- Increment visit count in the offline data and save back
	if not offlineData.social then
		offlineData.social = { gardenRating = 0, visitCount = 0, giftsGiven = 0, giftsReceived = 0 }
	end
	offlineData.social.visitCount = (offlineData.social.visitCount or 0) + 1
	offlineData.coins = (offlineData.coins or 0) + VISIT_COIN_REWARD

	-- Save updated offline data (fire-and-forget with retry)
	task.spawn(function()
		local key = `Player_{targetUserId}`
		for attempt = 1, 3 do
			local saveSuccess = pcall(function()
				PlayerDataStore:UpdateAsync(key, function(oldData)
					if not oldData then return offlineData end
					if not oldData.social then
						oldData.social = { gardenRating = 0, visitCount = 0, giftsGiven = 0, giftsReceived = 0 }
					end
					oldData.social.visitCount = (oldData.social.visitCount or 0) + 1
					oldData.coins = (oldData.coins or 0) + VISIT_COIN_REWARD
					return oldData
				end)
			end)
			if saveSuccess then break end
			task.wait(1)
		end
	end)

	activeVisits[player.UserId] = {
		targetUserId = targetUserId,
		targetName = targetName,
		gardenData = snapshot,
		enteredAt = os.time(),
		isOfflineGarden = true,
	}

	RE_VisitStarted:FireClient(player, snapshot)
end)

--------------------------------------------------------------------------------
-- Handle Arrivals from Cross-Server Teleport
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	-- Check if this player arrived with visit teleport data
	local success, teleportData = pcall(function()
		return player:GetJoinData().TeleportData
	end)

	if success and teleportData and teleportData.visitTargetUserId then
		local targetUserId = teleportData.visitTargetUserId

		-- Small delay for player to fully load
		task.delay(2, function()
			if not player.Parent then return end

			local targetPlayer = Players:GetPlayerByUserId(targetUserId)
			if targetPlayer then
				-- Target is here — enter visitor mode with live data
				local targetData = getPlayerData(targetPlayer)
				local snapshot = buildGardenSnapshot(targetData, targetUserId, targetPlayer.Name)

				targetData.social.visitCount += 1
				targetData.coins += VISIT_COIN_REWARD

				activeVisits[player.UserId] = {
					targetUserId = targetUserId,
					targetName = targetPlayer.Name,
					gardenData = snapshot,
					enteredAt = os.time(),
					isOfflineGarden = false,
				}

				RE_VisitStarted:FireClient(player, snapshot)
			else
				-- Target not on this server (they may have left)
				-- Fall back to offline garden
				local offlineData, err = loadOfflineGarden(targetUserId)
				if offlineData then
					local targetName = getPlayerName(targetUserId)
					local snapshot = buildGardenSnapshot(offlineData, targetUserId, targetName)

					activeVisits[player.UserId] = {
						targetUserId = targetUserId,
						targetName = targetName,
						gardenData = snapshot,
						enteredAt = os.time(),
						isOfflineGarden = true,
					}

					RE_VisitStarted:FireClient(player, snapshot)
				else
					RE_VisitFailed:FireClient(player, "TARGET_NOT_FOUND")
				end
			end
		end)
	end
end)

--------------------------------------------------------------------------------
-- Leave Garden (return to own garden)
--------------------------------------------------------------------------------

RE_LeaveGarden.OnServerEvent:Connect(function(player: Player)
	local visit = activeVisits[player.UserId]
	if not visit then return end

	activeVisits[player.UserId] = nil

	-- If the player arrived via teleport, send them back
	-- For simplicity, just notify the client to switch back to own garden view.
	-- A full implementation would teleport back to the original server,
	-- but the player's data persists across servers via DataStore.
	RE_VisitEnded:FireClient(player)
end)

--------------------------------------------------------------------------------
-- Rating System
--------------------------------------------------------------------------------

RE_RateGarden.OnServerEvent:Connect(function(player: Player, rating)
	-- Validate
	if typeof(rating) ~= "number" then return end
	if rating ~= math.floor(rating) then return end
	if rating < 1 or rating > 5 then return end

	local visit = activeVisits[player.UserId]
	if not visit then
		RE_RateResult:FireClient(player, false, "NOT_VISITING")
		return
	end

	-- Cooldown check
	if not ratingCooldowns[player.UserId] then
		ratingCooldowns[player.UserId] = {}
	end
	local lastRated = ratingCooldowns[player.UserId][visit.targetUserId] or 0
	if os.time() - lastRated < RATING_COOLDOWN then
		local remaining = RATING_COOLDOWN - (os.time() - lastRated)
		RE_RateResult:FireClient(player, false, "COOLDOWN", remaining)
		return
	end

	ratingCooldowns[player.UserId][visit.targetUserId] = os.time()

	-- Apply rating
	local targetUserId = visit.targetUserId
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)

	if targetPlayer and not visit.isOfflineGarden then
		-- Online — update live data with rolling average
		local targetData = getPlayerData(targetPlayer)
		local currentRating = targetData.social.gardenRating or 0
		local currentVisits = math.max(targetData.social.visitCount, 1)

		-- Weighted rolling average: bias toward recent ratings
		-- Use min(visitCount, 50) as the weight base so early ratings
		-- have more impact but the average stabilizes over time
		local weight = math.min(currentVisits, 50)
		local newRating = (currentRating * (weight - 1) + rating) / weight
		targetData.social.gardenRating = math.floor(newRating * 100) / 100 -- 2 decimal places

		RE_RateResult:FireClient(player, true, nil, nil, {
			newRating = targetData.social.gardenRating,
			yourRating = rating,
			ownerName = visit.targetName,
		})
	else
		-- Offline — update via DataStore
		task.spawn(function()
			local key = `Player_{targetUserId}`
			local saveSuccess = pcall(function()
				PlayerDataStore:UpdateAsync(key, function(oldData)
					if not oldData then return nil end
					if not oldData.social then
						oldData.social = { gardenRating = 0, visitCount = 0, giftsGiven = 0, giftsReceived = 0 }
					end

					local currentRating = oldData.social.gardenRating or 0
					local currentVisits = math.max(oldData.social.visitCount or 1, 1)
					local weight = math.min(currentVisits, 50)
					local newRating = (currentRating * (weight - 1) + rating) / weight
					oldData.social.gardenRating = math.floor(newRating * 100) / 100

					return oldData
				end)
			end)

			if not saveSuccess then
				warn(`Failed to save rating for offline player {targetUserId}`)
			end
		end)

		RE_RateResult:FireClient(player, true, nil, nil, {
			yourRating = rating,
			ownerName = visit.targetName,
		})
	end

	-- Update the snapshot shown to the visitor
	visit.gardenData.gardenRating = visit.gardenData.gardenRating or 0
	local snapWeight = math.min(visit.gardenData.visitCount or 1, 50)
	visit.gardenData.gardenRating = math.floor(
		((visit.gardenData.gardenRating * (snapWeight - 1) + rating) / snapWeight) * 100
	) / 100
end)

--------------------------------------------------------------------------------
-- Search for Gardens
--------------------------------------------------------------------------------

RF_SearchGardens.OnServerInvoke = function(player: Player, searchType: string, query: string?)
	if typeof(searchType) ~= "string" then return {} end

	local results = {}

	if searchType == "server" then
		-- List all players on this server (excluding self and current visitors)
		for _, other in Players:GetPlayers() do
			if other.UserId == player.UserId then continue end
			if isVisiting(other.UserId) then continue end

			local otherData = getPlayerData(other)
			table.insert(results, {
				userId = other.UserId,
				name = other.Name,
				gardenRating = otherData.social.gardenRating,
				visitCount = otherData.social.visitCount,
				totalHarvests = otherData.stats.totalHarvests,
				isOnline = true,
				sameServer = true,
			})
		end

	elseif searchType == "online" then
		-- List all known online players from presence cache
		local now = os.time()
		for userId, info in playerPresence do
			if userId == player.UserId then continue end
			if now - info.lastSeen > PRESENCE_TTL then continue end

			-- Skip players on this server (already in "server" search)
			if info.serverId == SERVER_ID then continue end

			table.insert(results, {
				userId = userId,
				name = info.playerName,
				gardenRating = 0, -- not available from presence data
				visitCount = 0,
				isOnline = true,
				sameServer = false,
			})

			if #results >= SEARCH_RESULT_LIMIT then break end
		end

	elseif searchType == "name" then
		-- Search by name — check server first, then presence
		if typeof(query) ~= "string" or #query < 1 then return {} end
		local lowerQuery = string.lower(query)

		for _, other in Players:GetPlayers() do
			if other.UserId == player.UserId then continue end
			if string.find(string.lower(other.Name), lowerQuery, 1, true) then
				local otherData = getPlayerData(other)
				table.insert(results, {
					userId = other.UserId,
					name = other.Name,
					gardenRating = otherData.social.gardenRating,
					visitCount = otherData.social.visitCount,
					isOnline = true,
					sameServer = true,
				})
			end
		end

		for userId, info in playerPresence do
			if userId == player.UserId then continue end
			if info.serverId == SERVER_ID then continue end
			if string.find(string.lower(info.playerName), lowerQuery, 1, true) then
				table.insert(results, {
					userId = userId,
					name = info.playerName,
					gardenRating = 0,
					isOnline = true,
					sameServer = false,
				})
			end
			if #results >= SEARCH_RESULT_LIMIT then break end
		end

	elseif searchType == "userId" then
		-- Direct userId lookup (for deep links / friend list)
		if typeof(query) ~= "string" then return {} end
		local targetId = tonumber(query)
		if not targetId then return {} end
		if targetId == player.UserId then return {} end

		local name = getPlayerName(targetId)
		local isOnline = Players:GetPlayerByUserId(targetId) ~= nil
		local sameServer = isOnline
		if not isOnline then
			local presence = playerPresence[targetId]
			if presence and os.time() - presence.lastSeen < PRESENCE_TTL then
				isOnline = true
				sameServer = presence.serverId == SERVER_ID
			end
		end

		table.insert(results, {
			userId = targetId,
			name = name,
			gardenRating = 0,
			isOnline = isOnline,
			sameServer = sameServer,
		})
	end

	-- Sort by rating descending
	table.sort(results, function(a, b)
		return (a.gardenRating or 0) > (b.gardenRating or 0)
	end)

	return results
end

--------------------------------------------------------------------------------
-- Get Garden View (for client to re-fetch snapshot while visiting)
--------------------------------------------------------------------------------

RF_GetGardenView.OnServerInvoke = function(player: Player)
	local visit = activeVisits[player.UserId]
	if not visit then return nil end

	-- Refresh live data if the owner is on this server
	if not visit.isOfflineGarden then
		local targetPlayer = Players:GetPlayerByUserId(visit.targetUserId)
		if targetPlayer then
			local targetData = getPlayerData(targetPlayer)
			visit.gardenData = buildGardenSnapshot(targetData, visit.targetUserId, visit.targetName)
		end
	end

	return visit.gardenData
end

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId

	-- End any active visit
	activeVisits[userId] = nil
	ratingCooldowns[userId] = nil

	-- Remove from presence
	playerPresence[userId] = nil
end)
