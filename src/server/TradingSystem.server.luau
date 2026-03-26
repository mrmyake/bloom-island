-- TradingSystem: Player-to-player trading of seeds, items, creatures, and coins.
-- Full server-side validation. Includes trade history logging.
--
-- Trade Flow:
--   1. Player A sends a trade request to Player B  (RE_RequestTrade)
--   2. Player B accepts or declines the request     (RE_RespondTrade)
--   3. Both players set their offers                (RE_SetTradeOffer)
--   4. Both players confirm (lock in)               (RE_ConfirmTrade)
--   5. Server validates and executes the swap        → RE_TradeCompleted
--   Either player can cancel at any time             (RE_CancelTrade)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local CreatureData = require(Shared.Config.CreatureData)
local MutationData = require(Shared.Config.MutationData)
local GameConfig = require(Shared.Config.GameConfig)
local DataManager = require(script.Parent.DataManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local MAX_TRADE_HISTORY = 50 -- per player, oldest entries pruned
local TRADE_REQUEST_TIMEOUT = 30 -- seconds to accept/decline
local MAX_CREATURES_PER_TRADE = 3
local MAX_SEED_STACKS_PER_TRADE = 10 -- max distinct seed types in one offer
local MAX_ITEM_STACKS_PER_TRADE = 10
local TRADE_COOLDOWN = 2 -- seconds between trade requests

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

local function getPlayerData(player: Player)
	return DataManager.getData(player.UserId)
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local RE_RequestTrade = getOrCreateRemote("RemoteEvent", "RE_RequestTrade")
local RE_RespondTrade = getOrCreateRemote("RemoteEvent", "RE_RespondTrade")
local RE_SetTradeOffer = getOrCreateRemote("RemoteEvent", "RE_SetTradeOffer")
local RE_ConfirmTrade = getOrCreateRemote("RemoteEvent", "RE_ConfirmTrade")
local RE_CancelTrade = getOrCreateRemote("RemoteEvent", "RE_CancelTrade")

-- Server → Client notifications
local RE_TradeRequested = getOrCreateRemote("RemoteEvent", "RE_TradeRequested")
local RE_TradeOpened = getOrCreateRemote("RemoteEvent", "RE_TradeOpened")
local RE_TradeOfferUpdated = getOrCreateRemote("RemoteEvent", "RE_TradeOfferUpdated")
local RE_TradeConfirmStatus = getOrCreateRemote("RemoteEvent", "RE_TradeConfirmStatus")
local RE_TradeCompleted = getOrCreateRemote("RemoteEvent", "RE_TradeCompleted")
local RE_TradeCancelled = getOrCreateRemote("RemoteEvent", "RE_TradeCancelled")
local RE_TradeFailed = getOrCreateRemote("RemoteEvent", "RE_TradeFailed")

local RF_GetTradeHistory = getOrCreateRemote("RemoteFunction", "RF_GetTradeHistory")
local RF_GetTradeValue = getOrCreateRemote("RemoteFunction", "RF_GetTradeValue")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type TradeOffer = {
	coins: number,
	seeds: { [string]: number },
	items: { [string]: number },
	creatureIndices: { number },
	confirmed: boolean,
}

type TradeSession = {
	id: string,
	playerA: number, -- UserId
	playerB: number, -- UserId
	offerA: TradeOffer,
	offerB: TradeOffer,
	createdAt: number,
	state: string, -- "pending" | "open" | "completed" | "cancelled"
}

type TradeHistoryEntry = {
	tradeId: string,
	partnerId: number,
	partnerName: string,
	timestamp: number,
	gave: { coins: number, seeds: { [string]: number }, items: { [string]: number }, creatures: { string } },
	received: { coins: number, seeds: { [string]: number }, items: { [string]: number }, creatures: { string } },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Active trade sessions: tradeId -> TradeSession
local activeTrades: { [string]: TradeSession } = {}

-- Which trade each player is in: UserId -> tradeId
local playerTradeMap: { [number]: string } = {}

-- Pending requests: targetUserId -> { fromUserId, tradeId, expiresAt }
local pendingRequests: { [number]: { fromUserId: number, tradeId: string, expiresAt: number } } = {}

-- Cooldowns: UserId -> last request timestamp
local tradeCooldowns: { [number]: number } = {}

-- Trade history: UserId -> { TradeHistoryEntry }
local tradeHistory: { [number]: { TradeHistoryEntry } } = {}

-- Trade ID counter
local tradeIdCounter = 0

local function generateTradeId(): string
	tradeIdCounter += 1
	return `trade_{os.time()}_{tradeIdCounter}`
end

local function createEmptyOffer(): TradeOffer
	return {
		coins = 0,
		seeds = {},
		items = {},
		creatureIndices = {},
		confirmed = false,
	}
end

local function isPlayerInTrade(userId: number): boolean
	return playerTradeMap[userId] ~= nil
end

local function getTradeForPlayer(userId: number): TradeSession?
	local tradeId = playerTradeMap[userId]
	if not tradeId then return nil end
	return activeTrades[tradeId]
end

local function getOtherUserId(trade: TradeSession, userId: number): number
	return if userId == trade.playerA then trade.playerB else trade.playerA
end

local function getOffer(trade: TradeSession, userId: number): TradeOffer
	return if userId == trade.playerA then trade.offerA else trade.offerB
end

local function cleanupTrade(tradeId: string)
	local trade = activeTrades[tradeId]
	if not trade then return end

	playerTradeMap[trade.playerA] = nil
	playerTradeMap[trade.playerB] = nil
	activeTrades[tradeId] = nil
end

local function cleanupPendingRequest(targetUserId: number)
	local pending = pendingRequests[targetUserId]
	if pending then
		-- Also clean up the requester's trade map if it points to this pending trade
		if playerTradeMap[pending.fromUserId] == pending.tradeId then
			playerTradeMap[pending.fromUserId] = nil
		end
		activeTrades[pending.tradeId] = nil
		pendingRequests[targetUserId] = nil
	end
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

local function validateOfferTable(offer): boolean
	if typeof(offer) ~= "table" then return false end

	-- Coins
	if offer.coins ~= nil then
		if typeof(offer.coins) ~= "number" then return false end
		if offer.coins < 0 or offer.coins ~= math.floor(offer.coins) then return false end
	end

	-- Seeds
	if offer.seeds ~= nil then
		if typeof(offer.seeds) ~= "table" then return false end
		local seedCount = 0
		for seedId, count in offer.seeds do
			if typeof(seedId) ~= "string" then return false end
			if typeof(count) ~= "number" then return false end
			if count < 0 or count ~= math.floor(count) then return false end
			if not PlantData[seedId] then return false end
			if count > 0 then seedCount += 1 end
		end
		if seedCount > MAX_SEED_STACKS_PER_TRADE then return false end
	end

	-- Items
	if offer.items ~= nil then
		if typeof(offer.items) ~= "table" then return false end
		local itemCount = 0
		for itemId, count in offer.items do
			if typeof(itemId) ~= "string" then return false end
			if typeof(count) ~= "number" then return false end
			if count < 0 or count ~= math.floor(count) then return false end
			if count > 0 then itemCount += 1 end
		end
		if itemCount > MAX_ITEM_STACKS_PER_TRADE then return false end
	end

	-- Creature indices
	if offer.creatureIndices ~= nil then
		if typeof(offer.creatureIndices) ~= "table" then return false end
		if #offer.creatureIndices > MAX_CREATURES_PER_TRADE then return false end
		local seen = {}
		for _, idx in offer.creatureIndices do
			if typeof(idx) ~= "number" then return false end
			if idx ~= math.floor(idx) then return false end
			if idx < 1 then return false end
			if seen[idx] then return false end -- no duplicates
			seen[idx] = true
		end
	end

	return true
end

-- Verify the player actually owns everything in their offer
local function validateOwnership(data, offer: TradeOffer): (boolean, string?)
	-- Coins
	if offer.coins > data.coins then
		return false, "NOT_ENOUGH_COINS"
	end

	-- Seeds
	for seedId, count in offer.seeds do
		if count <= 0 then continue end
		local owned = data.inventory.seeds[seedId] or 0
		if owned < count then
			return false, "NOT_ENOUGH_SEEDS"
		end
	end

	-- Items
	for itemId, count in offer.items do
		if count <= 0 then continue end
		local owned = data.inventory.items[itemId] or 0
		if owned < count then
			return false, "NOT_ENOUGH_ITEMS"
		end
	end

	-- Creatures
	for _, creatureIndex in offer.creatureIndices do
		if creatureIndex > #data.creatures then
			return false, "INVALID_CREATURE"
		end
		if not data.creatures[creatureIndex] then
			return false, "INVALID_CREATURE"
		end
	end

	-- Creature capacity check for receiving partner is done at execution time
	return true, nil
end

-- Check that the receiver has room for incoming creatures
local function validateCreatureCapacity(receiverData, incomingCount: number, outgoingCount: number): boolean
	local currentCount = #receiverData.creatures
	local netChange = incomingCount - outgoingCount
	return (currentCount + netChange) <= CreatureData.MAX_CREATURES
end

--------------------------------------------------------------------------------
-- Offer Summarization (for history + client display)
--------------------------------------------------------------------------------

local function summarizeOffer(offer: TradeOffer, playerData): { coins: number, seeds: { [string]: number }, items: { [string]: number }, creatures: { string } }
	local creatures = {}
	for _, idx in offer.creatureIndices do
		local creature = playerData.creatures[idx]
		if creature then
			local def = CreatureData.Creatures[creature.creatureId]
			local name = if creature.evolved and def then def.evolvedName
				elseif def then def.name
				else creature.creatureId
			table.insert(creatures, name)
		end
	end

	-- Filter out zero-count entries
	local seeds = {}
	for id, count in offer.seeds do
		if count > 0 then seeds[id] = count end
	end
	local items = {}
	for id, count in offer.items do
		if count > 0 then items[id] = count end
	end

	return {
		coins = offer.coins,
		seeds = seeds,
		items = items,
		creatures = creatures,
	}
end

--------------------------------------------------------------------------------
-- Trade Execution
--------------------------------------------------------------------------------

local function executeTrade(trade: TradeSession): (boolean, string?)
	local playerA = Players:GetPlayerByUserId(trade.playerA)
	local playerB = Players:GetPlayerByUserId(trade.playerB)
	if not playerA or not playerB then
		return false, "PLAYER_LEFT"
	end

	local dataA = getPlayerData(playerA)
	local dataB = getPlayerData(playerB)

	-- Re-validate ownership at execution time (state may have changed)
	local validA, errA = validateOwnership(dataA, trade.offerA)
	if not validA then return false, errA end

	local validB, errB = validateOwnership(dataB, trade.offerB)
	if not validB then return false, errB end

	-- Validate creature capacity for both sides
	local aIncoming = #trade.offerB.creatureIndices
	local aOutgoing = #trade.offerA.creatureIndices
	local bIncoming = #trade.offerA.creatureIndices
	local bOutgoing = #trade.offerB.creatureIndices

	if not validateCreatureCapacity(dataA, aIncoming, aOutgoing) then
		return false, "A_CREATURES_FULL"
	end
	if not validateCreatureCapacity(dataB, bIncoming, bOutgoing) then
		return false, "B_CREATURES_FULL"
	end

	-- Snapshot summaries before modifying data (creature names need current state)
	local summaryA = summarizeOffer(trade.offerA, dataA)
	local summaryB = summarizeOffer(trade.offerB, dataB)

	-- === Execute the swap ===

	-- 1. Transfer coins
	dataA.coins -= trade.offerA.coins
	dataA.coins += trade.offerB.coins
	dataB.coins -= trade.offerB.coins
	dataB.coins += trade.offerA.coins

	-- 2. Transfer seeds
	for seedId, count in trade.offerA.seeds do
		if count <= 0 then continue end
		dataA.inventory.seeds[seedId] = (dataA.inventory.seeds[seedId] or 0) - count
		if dataA.inventory.seeds[seedId] <= 0 then dataA.inventory.seeds[seedId] = nil end
		dataB.inventory.seeds[seedId] = (dataB.inventory.seeds[seedId] or 0) + count
	end
	for seedId, count in trade.offerB.seeds do
		if count <= 0 then continue end
		dataB.inventory.seeds[seedId] = (dataB.inventory.seeds[seedId] or 0) - count
		if dataB.inventory.seeds[seedId] <= 0 then dataB.inventory.seeds[seedId] = nil end
		dataA.inventory.seeds[seedId] = (dataA.inventory.seeds[seedId] or 0) + count
	end

	-- 3. Transfer items
	for itemId, count in trade.offerA.items do
		if count <= 0 then continue end
		dataA.inventory.items[itemId] = (dataA.inventory.items[itemId] or 0) - count
		if dataA.inventory.items[itemId] <= 0 then dataA.inventory.items[itemId] = nil end
		dataB.inventory.items[itemId] = (dataB.inventory.items[itemId] or 0) + count
	end
	for itemId, count in trade.offerB.items do
		if count <= 0 then continue end
		dataB.inventory.items[itemId] = (dataB.inventory.items[itemId] or 0) - count
		if dataB.inventory.items[itemId] <= 0 then dataB.inventory.items[itemId] = nil end
		dataA.inventory.items[itemId] = (dataA.inventory.items[itemId] or 0) + count
	end

	-- 4. Transfer creatures (must remove in descending index order to preserve indices)
	local creaturesFromA = {}
	local sortedIndicesA = table.clone(trade.offerA.creatureIndices)
	table.sort(sortedIndicesA, function(a, b) return a > b end) -- descending
	for _, idx in sortedIndicesA do
		table.insert(creaturesFromA, table.remove(dataA.creatures, idx))
	end

	local creaturesFromB = {}
	local sortedIndicesB = table.clone(trade.offerB.creatureIndices)
	table.sort(sortedIndicesB, function(a, b) return a > b end) -- descending
	for _, idx in sortedIndicesB do
		table.insert(creaturesFromB, table.remove(dataB.creatures, idx))
	end

	-- Add received creatures
	for _, creature in creaturesFromB do
		table.insert(dataA.creatures, creature)
	end
	for _, creature in creaturesFromA do
		table.insert(dataB.creatures, creature)
	end

	-- === Log trade history ===
	local historyEntryA: TradeHistoryEntry = {
		tradeId = trade.id,
		partnerId = trade.playerB,
		partnerName = playerB.Name,
		timestamp = os.time(),
		gave = summaryA,
		received = summaryB,
	}
	local historyEntryB: TradeHistoryEntry = {
		tradeId = trade.id,
		partnerId = trade.playerA,
		partnerName = playerA.Name,
		timestamp = os.time(),
		gave = summaryB,
		received = summaryA,
	}

	if not tradeHistory[trade.playerA] then tradeHistory[trade.playerA] = {} end
	if not tradeHistory[trade.playerB] then tradeHistory[trade.playerB] = {} end

	table.insert(tradeHistory[trade.playerA], historyEntryA)
	table.insert(tradeHistory[trade.playerB], historyEntryB)

	-- Prune old history
	while #tradeHistory[trade.playerA] > MAX_TRADE_HISTORY do
		table.remove(tradeHistory[trade.playerA], 1)
	end
	while #tradeHistory[trade.playerB] > MAX_TRADE_HISTORY do
		table.remove(tradeHistory[trade.playerB], 1)
	end

	-- Update social stats
	dataA.social.giftsGiven += 1
	dataA.social.giftsReceived += 1
	dataB.social.giftsGiven += 1
	dataB.social.giftsReceived += 1

	-- Award season pass XP for completing a trade
	local seasonXPEvent = ServerStorage:FindFirstChild("BE_SeasonXPEvent")
	if seasonXPEvent then
		(seasonXPEvent :: BindableEvent):Fire(trade.playerA, 30, "tradeComplete")
		(seasonXPEvent :: BindableEvent):Fire(trade.playerB, 30, "tradeComplete")
	end

	trade.state = "completed"
	return true, nil
end

--------------------------------------------------------------------------------
-- Estimate Trade Value (for UI display, not authoritative)
--------------------------------------------------------------------------------

local function estimateOfferValue(offer: TradeOffer, playerData): number
	local value = offer.coins

	for seedId, count in offer.seeds do
		local plant = PlantData[seedId]
		if plant and count > 0 then
			value += plant.baseValue * count
		end
	end

	for _, creatureIndex in offer.creatureIndices do
		local creature = playerData.creatures[creatureIndex]
		if creature then
			local def = CreatureData.Creatures[creature.creatureId]
			if def then
				-- Base value from rarity + level scaling + evolution bonus
				local rarityValues = { Common = 200, Uncommon = 600, Rare = 2000, Epic = 6000, Legendary = 20000 }
				local base = rarityValues[def.rarity] or 200
				local levelMult = 1 + (creature.level - 1) * 0.1
				local evolveMult = if creature.evolved then 2 else 1
				value += math.floor(base * levelMult * evolveMult)
			end
		end
	end

	return value
end

--------------------------------------------------------------------------------
-- Request Trade
--------------------------------------------------------------------------------

RE_RequestTrade.OnServerEvent:Connect(function(player: Player, targetUserId)
	-- Validate types
	if typeof(targetUserId) ~= "number" then return end

	-- Can't trade with yourself
	if targetUserId == player.UserId then return end

	-- Cooldown
	local lastRequest = tradeCooldowns[player.UserId] or 0
	if os.time() - lastRequest < TRADE_COOLDOWN then return end
	tradeCooldowns[player.UserId] = os.time()

	-- Neither player can already be in a trade
	if isPlayerInTrade(player.UserId) then
		RE_TradeFailed:FireClient(player, "ALREADY_IN_TRADE")
		return
	end
	if isPlayerInTrade(targetUserId) then
		RE_TradeFailed:FireClient(player, "TARGET_IN_TRADE")
		return
	end

	-- Target must be in the server
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer then
		RE_TradeFailed:FireClient(player, "PLAYER_NOT_FOUND")
		return
	end

	-- Clear any stale pending request for the target
	cleanupPendingRequest(targetUserId)

	-- Create the trade session in pending state
	local tradeId = generateTradeId()
	local trade: TradeSession = {
		id = tradeId,
		playerA = player.UserId,
		playerB = targetUserId,
		offerA = createEmptyOffer(),
		offerB = createEmptyOffer(),
		createdAt = os.time(),
		state = "pending",
	}

	activeTrades[tradeId] = trade
	playerTradeMap[player.UserId] = tradeId

	pendingRequests[targetUserId] = {
		fromUserId = player.UserId,
		tradeId = tradeId,
		expiresAt = os.time() + TRADE_REQUEST_TIMEOUT,
	}

	-- Notify target player
	RE_TradeRequested:FireClient(targetPlayer, player.UserId, player.Name, TRADE_REQUEST_TIMEOUT)

	-- Auto-expire the request
	task.delay(TRADE_REQUEST_TIMEOUT, function()
		local pending = pendingRequests[targetUserId]
		if pending and pending.tradeId == tradeId then
			cleanupPendingRequest(targetUserId)
			-- Notify both players
			if player.Parent then
				RE_TradeCancelled:FireClient(player, "REQUEST_EXPIRED")
			end
			if targetPlayer.Parent then
				RE_TradeCancelled:FireClient(targetPlayer, "REQUEST_EXPIRED")
			end
		end
	end)
end)

--------------------------------------------------------------------------------
-- Respond to Trade Request
--------------------------------------------------------------------------------

RE_RespondTrade.OnServerEvent:Connect(function(player: Player, accepted)
	if typeof(accepted) ~= "boolean" then return end

	local pending = pendingRequests[player.UserId]
	if not pending then return end
	if os.time() > pending.expiresAt then
		cleanupPendingRequest(player.UserId)
		return
	end

	local trade = activeTrades[pending.tradeId]
	if not trade then
		cleanupPendingRequest(player.UserId)
		return
	end

	local requester = Players:GetPlayerByUserId(pending.fromUserId)
	pendingRequests[player.UserId] = nil

	if not accepted then
		cleanupTrade(trade.id)
		if requester then
			RE_TradeCancelled:FireClient(requester, "REQUEST_DECLINED")
		end
		return
	end

	-- Check the responder isn't now in another trade
	if isPlayerInTrade(player.UserId) then
		cleanupTrade(trade.id)
		if requester then
			RE_TradeCancelled:FireClient(requester, "TARGET_IN_TRADE")
		end
		return
	end

	if not requester then
		cleanupTrade(trade.id)
		RE_TradeFailed:FireClient(player, "PLAYER_LEFT")
		return
	end

	-- Open the trade
	trade.state = "open"
	playerTradeMap[player.UserId] = trade.id

	RE_TradeOpened:FireClient(requester, player.UserId, player.Name)
	RE_TradeOpened:FireClient(player, pending.fromUserId, requester.Name)
end)

--------------------------------------------------------------------------------
-- Set Trade Offer
--------------------------------------------------------------------------------

RE_SetTradeOffer.OnServerEvent:Connect(function(player: Player, offerData)
	local trade = getTradeForPlayer(player.UserId)
	if not trade or trade.state ~= "open" then return end

	-- Validate the raw offer table from the client
	if not validateOfferTable(offerData) then return end

	local data = getPlayerData(player)
	local offer = getOffer(trade, player.UserId)

	-- Build sanitized offer
	offer.coins = offerData.coins or 0
	offer.seeds = offerData.seeds or {}
	offer.items = offerData.items or {}
	offer.creatureIndices = offerData.creatureIndices or {}

	-- Validate ownership
	local valid, err = validateOwnership(data, offer)
	if not valid then
		-- Revert to empty
		offer.coins = 0
		offer.seeds = {}
		offer.items = {}
		offer.creatureIndices = {}
		RE_TradeFailed:FireClient(player, err)
		return
	end

	-- Reset confirmations whenever an offer changes
	trade.offerA.confirmed = false
	trade.offerB.confirmed = false

	-- Notify both players of the updated offer
	local otherUserId = getOtherUserId(trade, player.UserId)
	local otherPlayer = Players:GetPlayerByUserId(otherUserId)

	local summary = summarizeOffer(offer, data)
	local value = estimateOfferValue(offer, data)

	RE_TradeOfferUpdated:FireClient(player, player.UserId, summary, value)
	if otherPlayer then
		RE_TradeOfferUpdated:FireClient(otherPlayer, player.UserId, summary, value)
	end
end)

--------------------------------------------------------------------------------
-- Confirm Trade
--------------------------------------------------------------------------------

RE_ConfirmTrade.OnServerEvent:Connect(function(player: Player)
	local trade = getTradeForPlayer(player.UserId)
	if not trade or trade.state ~= "open" then return end

	local offer = getOffer(trade, player.UserId)
	offer.confirmed = true

	-- Notify both players of confirmation status
	local otherUserId = getOtherUserId(trade, player.UserId)
	local otherPlayer = Players:GetPlayerByUserId(otherUserId)

	RE_TradeConfirmStatus:FireClient(player, player.UserId, true)
	if otherPlayer then
		RE_TradeConfirmStatus:FireClient(otherPlayer, player.UserId, true)
	end

	-- If both confirmed, execute
	if trade.offerA.confirmed and trade.offerB.confirmed then
		local success, err = executeTrade(trade)

		local playerA = Players:GetPlayerByUserId(trade.playerA)
		local playerB = Players:GetPlayerByUserId(trade.playerB)

		if success then
			local dataA = playerA and getPlayerData(playerA) or nil
			local dataB = playerB and getPlayerData(playerB) or nil

			if playerA then
				RE_TradeCompleted:FireClient(playerA, trade.id, {
					coins = dataA and dataA.coins or 0,
				})
			end
			if playerB then
				RE_TradeCompleted:FireClient(playerB, trade.id, {
					coins = dataB and dataB.coins or 0,
				})
			end
		else
			if playerA then
				RE_TradeFailed:FireClient(playerA, err)
			end
			if playerB then
				RE_TradeFailed:FireClient(playerB, err)
			end
		end

		cleanupTrade(trade.id)
	end
end)

--------------------------------------------------------------------------------
-- Cancel Trade
--------------------------------------------------------------------------------

RE_CancelTrade.OnServerEvent:Connect(function(player: Player)
	-- Check pending request first
	local pending = pendingRequests[player.UserId]
	if pending then
		local requester = Players:GetPlayerByUserId(pending.fromUserId)
		cleanupPendingRequest(player.UserId)
		if requester then
			RE_TradeCancelled:FireClient(requester, "CANCELLED_BY_TARGET")
		end
		return
	end

	local trade = getTradeForPlayer(player.UserId)
	if not trade then return end

	local otherUserId = getOtherUserId(trade, player.UserId)
	local otherPlayer = Players:GetPlayerByUserId(otherUserId)

	trade.state = "cancelled"
	cleanupTrade(trade.id)

	RE_TradeCancelled:FireClient(player, "YOU_CANCELLED")
	if otherPlayer then
		RE_TradeCancelled:FireClient(otherPlayer, "PARTNER_CANCELLED")
	end
end)

--------------------------------------------------------------------------------
-- Trade History Query
--------------------------------------------------------------------------------

RF_GetTradeHistory.OnServerInvoke = function(player: Player)
	local history = tradeHistory[player.UserId]
	if not history then return {} end

	-- Return in reverse chronological order
	local result = {}
	for i = #history, 1, -1 do
		table.insert(result, history[i])
	end
	return result
end

--------------------------------------------------------------------------------
-- Trade Value Estimation (client can request value estimate for any offer)
--------------------------------------------------------------------------------

RF_GetTradeValue.OnServerInvoke = function(player: Player, offerData)
	if not validateOfferTable(offerData) then return 0 end

	local data = getPlayerData(player)
	local tempOffer: TradeOffer = {
		coins = offerData.coins or 0,
		seeds = offerData.seeds or {},
		items = offerData.items or {},
		creatureIndices = offerData.creatureIndices or {},
		confirmed = false,
	}

	return estimateOfferValue(tempOffer, data)
end

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId

	-- Cancel any active trade
	local trade = getTradeForPlayer(userId)
	if trade then
		local otherUserId = getOtherUserId(trade, userId)
		local otherPlayer = Players:GetPlayerByUserId(otherUserId)
		trade.state = "cancelled"
		cleanupTrade(trade.id)
		if otherPlayer then
			RE_TradeCancelled:FireClient(otherPlayer, "PARTNER_LEFT")
		end
	end

	-- Cancel any pending request targeting this player
	cleanupPendingRequest(userId)

	-- Cancel any pending request FROM this player
	for targetId, pending in pendingRequests do
		if pending.fromUserId == userId then
			local targetPlayer = Players:GetPlayerByUserId(targetId)
			pendingRequests[targetId] = nil
			if targetPlayer then
				RE_TradeCancelled:FireClient(targetPlayer, "REQUESTER_LEFT")
			end
			break
		end
	end

	tradeCooldowns[userId] = nil
	tradeHistory[userId] = nil
end)

-- Cancel all trades on shutdown
game:BindToClose(function()
	for tradeId, trade in activeTrades do
		trade.state = "cancelled"
	end
	table.clear(activeTrades)
	table.clear(playerTradeMap)
	table.clear(pendingRequests)
end)
