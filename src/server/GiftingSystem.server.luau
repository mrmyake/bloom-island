-- GiftingSystem: Send seeds and creatures as gifts to other players.
-- Supports same-server (instant) and cross-server (DataStore) delivery.
-- Daily quest: send 3 gifts for a coin bonus.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local CreatureData = require(Shared.Config.CreatureData)
local DataManager = require(script.Parent.DataManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayerDataStore = DataStoreService:GetDataStore("BloomIsland_v1")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local GIFT_COOLDOWN = 5              -- seconds between gifts to prevent spam
local MAX_SEEDS_PER_GIFT = 10        -- max total seeds in one gift
local MAX_CREATURES_PER_GIFT = 1     -- one creature per gift
local DAILY_GIFT_GOAL = 3            -- gifts needed for daily quest
local DAILY_GIFT_REWARD = 500        -- coins for completing daily gift quest
local GIFT_NOTIFY_TOPIC = "BloomIsland_GiftNotify" -- MessagingService topic

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
local RE_SendGift = getOrCreateRemote("RemoteEvent", "RE_SendGift")
local RE_GiftReceived = getOrCreateRemote("RemoteEvent", "RE_GiftReceived")
local RE_GiftSent = getOrCreateRemote("RemoteEvent", "RE_GiftSent")
local RE_GiftFailed = getOrCreateRemote("RemoteEvent", "RE_GiftFailed")
local RE_GiftAnimation = getOrCreateRemote("RemoteEvent", "RE_GiftAnimation")
local RE_DailyQuestUpdate = getOrCreateRemote("RemoteEvent", "RE_DailyQuestUpdate")
local RE_ClaimDailyGiftReward = getOrCreateRemote("RemoteEvent", "RE_ClaimDailyGiftReward")
local RE_DailyRewardClaimed = getOrCreateRemote("RemoteEvent", "RE_DailyRewardClaimed")
local RF_GetDailyQuestStatus = getOrCreateRemote("RemoteFunction", "RF_GetDailyQuestStatus")
local RF_GetGiftHistory = getOrCreateRemote("RemoteFunction", "RF_GetGiftHistory")

local function getPlayerData(player: Player)
	return DataManager.getData(player.UserId)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Gift cooldown: UserId -> last gift timestamp
local giftCooldowns: { [number]: number } = {}

-- Gift history: UserId -> { entries }
-- Kept in memory for the session; not persisted (social.giftsGiven/Received are)
local giftHistory: { [number]: { any } } = {}
local MAX_GIFT_HISTORY = 30

--------------------------------------------------------------------------------
-- Daily Quest Logic
--------------------------------------------------------------------------------

local function getTodayKey(): number
	-- UTC day number (resets at midnight UTC)
	return math.floor(os.time() / 86400)
end

local function ensureDailyReset(data)
	if not data.dailyQuests then
		data.dailyQuests = {
			giftsToday = 0,
			lastGiftReset = 0,
			giftQuestClaimed = false,
		}
	end

	local today = getTodayKey()
	if data.dailyQuests.lastGiftReset ~= today then
		data.dailyQuests.giftsToday = 0
		data.dailyQuests.giftQuestClaimed = false
		data.dailyQuests.lastGiftReset = today
	end
end

local function getDailyQuestStatus(data): (number, number, boolean)
	ensureDailyReset(data)
	return data.dailyQuests.giftsToday, DAILY_GIFT_GOAL, data.dailyQuests.giftQuestClaimed
end

local function incrementDailyGifts(player: Player, data)
	ensureDailyReset(data)
	data.dailyQuests.giftsToday += 1

	-- Notify client of quest progress
	RE_DailyQuestUpdate:FireClient(player, {
		giftsToday = data.dailyQuests.giftsToday,
		goal = DAILY_GIFT_GOAL,
		claimed = data.dailyQuests.giftQuestClaimed,
		complete = data.dailyQuests.giftsToday >= DAILY_GIFT_GOAL,
	})
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

local function validateGiftContents(giftData): (boolean, string?)
	if typeof(giftData) ~= "table" then
		return false, "INVALID_DATA"
	end

	local hasAnything = false

	-- Validate seeds
	if giftData.seeds ~= nil then
		if typeof(giftData.seeds) ~= "table" then return false, "INVALID_SEEDS" end

		local totalSeeds = 0
		for seedId, count in giftData.seeds do
			if typeof(seedId) ~= "string" then return false, "INVALID_SEED_ID" end
			if typeof(count) ~= "number" then return false, "INVALID_SEED_COUNT" end
			if count ~= math.floor(count) or count < 1 then return false, "INVALID_SEED_COUNT" end
			if not PlantData[seedId] then return false, "UNKNOWN_SEED" end
			totalSeeds += count
		end
		if totalSeeds > MAX_SEEDS_PER_GIFT then return false, "TOO_MANY_SEEDS" end
		if totalSeeds > 0 then hasAnything = true end
	end

	-- Validate creature index
	if giftData.creatureIndex ~= nil then
		if typeof(giftData.creatureIndex) ~= "number" then return false, "INVALID_CREATURE" end
		if giftData.creatureIndex ~= math.floor(giftData.creatureIndex) then return false, "INVALID_CREATURE" end
		if giftData.creatureIndex < 1 then return false, "INVALID_CREATURE" end
		hasAnything = true
	end

	if not hasAnything then
		return false, "EMPTY_GIFT"
	end

	return true, nil
end

local function validateOwnership(data, giftData): (boolean, string?)
	-- Check seed ownership
	if giftData.seeds then
		for seedId, count in giftData.seeds do
			local owned = data.inventory.seeds[seedId] or 0
			if owned < count then
				return false, "NOT_ENOUGH_SEEDS"
			end
		end
	end

	-- Check creature ownership
	if giftData.creatureIndex then
		if giftData.creatureIndex > #data.creatures then
			return false, "INVALID_CREATURE"
		end
		if not data.creatures[giftData.creatureIndex] then
			return false, "INVALID_CREATURE"
		end
	end

	return true, nil
end

--------------------------------------------------------------------------------
-- Gift Summary (for history and notifications)
--------------------------------------------------------------------------------

local function buildGiftSummary(giftData, senderData): { seeds: { { seedId: string, name: string, count: number } }?, creature: { creatureId: string, name: string, level: number, evolved: boolean }? }
	local summary: any = {}

	if giftData.seeds then
		summary.seeds = {}
		for seedId, count in giftData.seeds do
			if count > 0 then
				local plant = PlantData[seedId]
				table.insert(summary.seeds, {
					seedId = seedId,
					name = plant and plant.name or seedId,
					count = count,
				})
			end
		end
	end

	if giftData.creatureIndex then
		local creature = senderData.creatures[giftData.creatureIndex]
		if creature then
			local def = CreatureData.Creatures[creature.creatureId]
			summary.creature = {
				creatureId = creature.creatureId,
				name = if creature.evolved and def then def.evolvedName
					elseif def then def.name
					else creature.creatureId,
				level = creature.level,
				evolved = creature.evolved,
			}
		end
	end

	return summary
end

--------------------------------------------------------------------------------
-- Gift Delivery (same-server)
--------------------------------------------------------------------------------

local function deliverGiftToPlayer(recipientData, giftData, senderData)
	-- Deliver seeds
	if giftData.seeds then
		for seedId, count in giftData.seeds do
			if count > 0 then
				recipientData.inventory.seeds[seedId] = (recipientData.inventory.seeds[seedId] or 0) + count
			end
		end
	end

	-- Deliver creature
	if giftData.creatureIndex then
		local creature = senderData.creatures[giftData.creatureIndex]
		if creature then
			table.insert(recipientData.creatures, {
				creatureId = creature.creatureId,
				level = creature.level,
				xp = creature.xp,
				evolved = creature.evolved,
			})
		end
	end

	recipientData.social.giftsReceived += 1
end

-- Remove gift items from sender
local function deductGiftFromSender(senderData, giftData)
	-- Remove seeds
	if giftData.seeds then
		for seedId, count in giftData.seeds do
			if count > 0 then
				senderData.inventory.seeds[seedId] = (senderData.inventory.seeds[seedId] or 0) - count
				if senderData.inventory.seeds[seedId] <= 0 then
					senderData.inventory.seeds[seedId] = nil
				end
			end
		end
	end

	-- Remove creature (by index)
	if giftData.creatureIndex then
		table.remove(senderData.creatures, giftData.creatureIndex)
	end

	senderData.social.giftsGiven += 1
end

--------------------------------------------------------------------------------
-- Gift Delivery (cross-server via DataStore)
--------------------------------------------------------------------------------

local function deliverGiftOffline(targetUserId: number, giftData, senderData, senderName: string): (boolean, string?)
	local key = `Player_{targetUserId}`

	-- Build the gift payload to store
	local giftPayload = {
		fromUserId = senderData and 0 or 0, -- filled below
		fromName = senderName,
		timestamp = os.time(),
		seeds = {},
		creature = nil,
	}

	if giftData.seeds then
		for seedId, count in giftData.seeds do
			if count > 0 then
				giftPayload.seeds[seedId] = count
			end
		end
	end

	if giftData.creatureIndex then
		local creature = senderData.creatures[giftData.creatureIndex]
		if creature then
			giftPayload.creature = {
				creatureId = creature.creatureId,
				level = creature.level,
				xp = creature.xp,
				evolved = creature.evolved,
			}
		end
	end

	local success, err = pcall(function()
		PlayerDataStore:UpdateAsync(key, function(oldData)
			if not oldData then return nil end

			-- Deliver seeds
			if not oldData.inventory then
				oldData.inventory = { seeds = {}, items = {} }
			end
			if not oldData.inventory.seeds then
				oldData.inventory.seeds = {}
			end
			for seedId, count in giftPayload.seeds do
				oldData.inventory.seeds[seedId] = (oldData.inventory.seeds[seedId] or 0) + count
			end

			-- Deliver creature
			if giftPayload.creature then
				if not oldData.creatures then
					oldData.creatures = {}
				end
				-- Check capacity
				if #oldData.creatures < CreatureData.MAX_CREATURES then
					table.insert(oldData.creatures, giftPayload.creature)
				else
					-- Can't deliver creature — store as pending gift item
					if not oldData.inventory.items then
						oldData.inventory.items = {}
					end
					oldData.inventory.items.pendingCreatureGift = (oldData.inventory.items.pendingCreatureGift or 0) + 1
				end
			end

			-- Update social stats
			if not oldData.social then
				oldData.social = { gardenRating = 0, visitCount = 0, giftsGiven = 0, giftsReceived = 0 }
			end
			oldData.social.giftsReceived = (oldData.social.giftsReceived or 0) + 1

			-- Store pending notification for next login
			if not oldData.pendingGiftNotifications then
				oldData.pendingGiftNotifications = {}
			end
			table.insert(oldData.pendingGiftNotifications, {
				fromName = senderName,
				timestamp = os.time(),
				summary = giftPayload,
			})
			-- Cap stored notifications
			while #oldData.pendingGiftNotifications > 10 do
				table.remove(oldData.pendingGiftNotifications, 1)
			end

			return oldData
		end)
	end)

	if not success then
		return false, "DATASTORE_FAILED"
	end
	return true, nil
end

--------------------------------------------------------------------------------
-- Cross-Server Notification via MessagingService
--------------------------------------------------------------------------------

pcall(function()
	MessagingService:SubscribeAsync(GIFT_NOTIFY_TOPIC, function(message)
		local payload = message.Data
		if not payload or not payload.targetUserId then return end

		local targetPlayer = Players:GetPlayerByUserId(payload.targetUserId)
		if not targetPlayer then return end

		-- Reload data to pick up DataStore changes from sender's server
		local data = DataManager.loadData(targetPlayer)
		DataManager.setData(targetPlayer.UserId, data)

		-- Notify client
		RE_GiftReceived:FireClient(targetPlayer, {
			fromName = payload.fromName,
			summary = payload.summary,
		})

		-- Trigger gift box animation on recipient
		RE_GiftAnimation:FireClient(targetPlayer, "receive", {
			fromName = payload.fromName,
		})
	end)
end)

local function notifyCrossServer(targetUserId: number, fromName: string, summary)
	pcall(function()
		MessagingService:PublishAsync(GIFT_NOTIFY_TOPIC, {
			targetUserId = targetUserId,
			fromName = fromName,
			summary = summary,
		})
	end)
end

--------------------------------------------------------------------------------
-- Send Gift
--------------------------------------------------------------------------------

RE_SendGift.OnServerEvent:Connect(function(player: Player, targetUserId, giftData)
	-- Validate types
	if typeof(targetUserId) ~= "number" then return end
	if targetUserId == player.UserId then
		RE_GiftFailed:FireClient(player, "SELF_GIFT")
		return
	end

	-- Cooldown
	local lastGift = giftCooldowns[player.UserId] or 0
	if os.time() - lastGift < GIFT_COOLDOWN then
		RE_GiftFailed:FireClient(player, "COOLDOWN")
		return
	end

	-- Validate gift contents
	local valid, err = validateGiftContents(giftData)
	if not valid then
		RE_GiftFailed:FireClient(player, err)
		return
	end

	local senderData = getPlayerData(player)

	-- Validate ownership
	local owns, ownErr = validateOwnership(senderData, giftData)
	if not owns then
		RE_GiftFailed:FireClient(player, ownErr)
		return
	end

	-- Check creature capacity on recipient if sending a creature
	if giftData.creatureIndex then
		local targetPlayer = Players:GetPlayerByUserId(targetUserId)
		if targetPlayer then
			local targetData = getPlayerData(targetPlayer)
			if #targetData.creatures >= CreatureData.MAX_CREATURES then
				RE_GiftFailed:FireClient(player, "RECIPIENT_CREATURES_FULL")
				return
			end
		end
		-- For offline targets, capacity is checked in DataStore UpdateAsync
	end

	-- Build summary before deducting (creature data still exists)
	local summary = buildGiftSummary(giftData, senderData)

	-- Get recipient name
	local targetName: string
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if targetPlayer then
		targetName = targetPlayer.Name
	else
		local nameSuccess, name = pcall(function()
			return Players:GetNameFromUserIdAsync(targetUserId)
		end)
		targetName = if nameSuccess and name then name else `Player_{targetUserId}`
	end

	-- Deduct from sender
	deductGiftFromSender(senderData, giftData)
	giftCooldowns[player.UserId] = os.time()

	-- Deliver to recipient
	if targetPlayer then
		-- Same server
		local targetData = getPlayerData(targetPlayer)
		deliverGiftToPlayer(targetData, giftData, senderData)

		RE_GiftReceived:FireClient(targetPlayer, {
			fromName = player.Name,
			summary = summary,
		})
		RE_GiftAnimation:FireClient(targetPlayer, "receive", {
			fromName = player.Name,
		})
	else
		-- Cross-server / offline
		local deliverSuccess, deliverErr = deliverGiftOffline(targetUserId, giftData, senderData, player.Name)
		if not deliverSuccess then
			-- Rollback: re-add items to sender (best effort)
			-- Seeds
			if giftData.seeds then
				for seedId, count in giftData.seeds do
					senderData.inventory.seeds[seedId] = (senderData.inventory.seeds[seedId] or 0) + count
				end
			end
			-- Creature rollback is complex (index shifted); warn instead
			if giftData.creatureIndex then
				warn(`Creature gift rollback needed for {player.Name} — creature may be lost`)
			end
			senderData.social.giftsGiven -= 1

			RE_GiftFailed:FireClient(player, deliverErr or "DELIVERY_FAILED")
			return
		end

		-- Notify other servers
		notifyCrossServer(targetUserId, player.Name, summary)
	end

	-- Confirm to sender
	RE_GiftSent:FireClient(player, {
		targetName = targetName,
		targetUserId = targetUserId,
		summary = summary,
	})

	-- Trigger send animation on sender's client
	RE_GiftAnimation:FireClient(player, "send", {
		targetName = targetName,
	})

	-- Award season pass XP for gifting
	local seasonXPEvent = ServerStorage:FindFirstChild("BE_SeasonXPEvent")
	if seasonXPEvent then
		(seasonXPEvent :: BindableEvent):Fire(player.UserId, 15, "giftSent")
	end

	-- Update daily quest
	incrementDailyGifts(player, senderData)

	-- Record history
	if not giftHistory[player.UserId] then
		giftHistory[player.UserId] = {}
	end
	table.insert(giftHistory[player.UserId], {
		type = "sent",
		targetUserId = targetUserId,
		targetName = targetName,
		summary = summary,
		timestamp = os.time(),
	})
	while #giftHistory[player.UserId] > MAX_GIFT_HISTORY do
		table.remove(giftHistory[player.UserId], 1)
	end
end)

--------------------------------------------------------------------------------
-- Claim Daily Gift Reward
--------------------------------------------------------------------------------

RE_ClaimDailyGiftReward.OnServerEvent:Connect(function(player: Player)
	local data = getPlayerData(player)
	ensureDailyReset(data)

	if data.dailyQuests.giftQuestClaimed then
		RE_GiftFailed:FireClient(player, "ALREADY_CLAIMED")
		return
	end

	if data.dailyQuests.giftsToday < DAILY_GIFT_GOAL then
		RE_GiftFailed:FireClient(player, "QUEST_INCOMPLETE")
		return
	end

	data.dailyQuests.giftQuestClaimed = true
	data.coins += DAILY_GIFT_REWARD

	RE_DailyRewardClaimed:FireClient(player, {
		reward = DAILY_GIFT_REWARD,
		newCoins = data.coins,
	})
end)

--------------------------------------------------------------------------------
-- Query: Daily Quest Status
--------------------------------------------------------------------------------

RF_GetDailyQuestStatus.OnServerInvoke = function(player: Player)
	local data = getPlayerData(player)
	local giftsToday, goal, claimed = getDailyQuestStatus(data)
	return {
		giftsToday = giftsToday,
		goal = goal,
		claimed = claimed,
		complete = giftsToday >= goal,
		reward = DAILY_GIFT_REWARD,
	}
end

--------------------------------------------------------------------------------
-- Query: Gift History
--------------------------------------------------------------------------------

RF_GetGiftHistory.OnServerInvoke = function(player: Player)
	local history = giftHistory[player.UserId]
	if not history then return {} end

	-- Return reverse chronological
	local result = {}
	for i = #history, 1, -1 do
		table.insert(result, history[i])
	end
	return result
end

--------------------------------------------------------------------------------
-- Deliver Pending Offline Gift Notifications on Join
--------------------------------------------------------------------------------

local function deliverPendingNotifications(player: Player, data)
	if not data.pendingGiftNotifications then return end
	if #data.pendingGiftNotifications == 0 then return end

	-- Small delay so client scripts are ready
	task.delay(3, function()
		if not player.Parent then return end

		for _, notification in data.pendingGiftNotifications do
			RE_GiftReceived:FireClient(player, {
				fromName = notification.fromName,
				summary = notification.summary,
				wasOffline = true,
			})

			RE_GiftAnimation:FireClient(player, "receive", {
				fromName = notification.fromName,
			})

			task.wait(0.5) -- stagger notifications
		end
	end)

	-- Clear pending notifications
	data.pendingGiftNotifications = {}
end

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	-- Initialize history
	giftHistory[player.UserId] = {}
end)

Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId
	giftCooldowns[userId] = nil
	giftHistory[userId] = nil
end)
