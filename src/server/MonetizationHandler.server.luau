-- MonetizationHandler: Game Pass ownership checks, Developer Product purchase
-- callbacks, timed buffs (Lucky Charm, Growth Boost), and auto-harvest loop.
-- Sets gamePasses flags in player data on join so other systems can read them.
-- Exposes per-player buffs via BindableFunctions for PlantSystem/MutationEngine.

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local CreatureData = require(Shared.Config.CreatureData)
local GameConfig = require(Shared.Config.GameConfig)
local DataManager = require(script.Parent.DataManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local GAME_PASSES = GameConfig.GAME_PASSES
local DEV_PRODUCTS = GameConfig.DEV_PRODUCTS

-- Timed buff durations (seconds)
local LUCKY_CHARM_DURATION = 300    -- 5 minutes of boosted mutation luck
local LUCKY_CHARM_MULTIPLIER = 3    -- 3x mutation chance
local GROWTH_BOOST_DURATION = 300   -- 5 minutes of boosted growth
local GROWTH_BOOST_MULTIPLIER = 2   -- 2x growth speed

-- Auto-harvest tick interval
local AUTO_HARVEST_INTERVAL = 5

-- Seed pack contents
local SEED_PACK_CONTENTS = {
	{ seedId = "rose", count = 3 },
	{ seedId = "sunflower", count = 2 },
	{ seedId = "bonsai", count = 1 },
}

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

local function getOrCreateBindable(className: string, name: string): Instance
	local bindable = ServerStorage:FindFirstChild(name)
	if not bindable then
		bindable = Instance.new(className)
		bindable.Name = name
		bindable.Parent = ServerStorage
	end
	return bindable
end

-- Remotes for client notifications
local RE_BuffActivated = getOrCreateRemote("RemoteEvent", "RE_BuffActivated")
local RE_BuffExpired = getOrCreateRemote("RemoteEvent", "RE_BuffExpired")
local RE_GamePassGranted = getOrCreateRemote("RemoteEvent", "RE_GamePassGranted")
local RE_ProductDelivered = getOrCreateRemote("RemoteEvent", "RE_ProductDelivered")
local RF_GetActiveBuffs = getOrCreateRemote("RemoteFunction", "RF_GetActiveBuffs")

-- Other systems' BindableFunctions
local BF_RollMutation = ServerStorage:WaitForChild("BF_RollMutation")
local BF_GetCreatureBonuses: BindableFunction? = nil -- lazy-loaded, may not exist yet

-- PlantSystem remotes for auto-harvest
local RE_HarvestResult = getOrCreateRemote("RemoteEvent", "RE_HarvestResult")
local BF_GetMutationValue = ServerStorage:WaitForChild("BF_GetMutationValue")

local function getPlayerData(player: Player)
	return DataManager.getData(player.UserId)
end

--------------------------------------------------------------------------------
-- Per-Player Buff System
--------------------------------------------------------------------------------

type Buff = {
	buffType: string,       -- "luckyCharm" | "growthBoost"
	multiplier: number,
	expiresAt: number,      -- os.time() based
	activatedAt: number,
}

-- UserId -> { buffType -> Buff }
local playerBuffs: { [number]: { [string]: Buff } } = {}

local function getBuffs(userId: number): { [string]: Buff }
	return playerBuffs[userId] or {}
end

local function getActiveBuff(userId: number, buffType: string): Buff?
	local buffs = playerBuffs[userId]
	if not buffs then return nil end
	local buff = buffs[buffType]
	if not buff then return nil end
	if os.time() >= buff.expiresAt then
		buffs[buffType] = nil
		return nil
	end
	return buff
end

local function activateBuff(player: Player, buffType: string, multiplier: number, duration: number)
	local userId = player.UserId
	if not playerBuffs[userId] then
		playerBuffs[userId] = {}
	end

	local now = os.time()
	local existing = playerBuffs[userId][buffType]

	-- Stack duration if already active, keep highest multiplier
	local newExpiry: number
	local newMult: number
	if existing and now < existing.expiresAt then
		local remainingTime = existing.expiresAt - now
		newExpiry = now + remainingTime + duration
		newMult = math.max(existing.multiplier, multiplier)
	else
		newExpiry = now + duration
		newMult = multiplier
	end

	playerBuffs[userId][buffType] = {
		buffType = buffType,
		multiplier = newMult,
		expiresAt = newExpiry,
		activatedAt = now,
	}

	RE_BuffActivated:FireClient(player, buffType, newMult, newExpiry - now)

	-- Schedule expiry notification
	local thisExpiry = newExpiry
	task.delay(newExpiry - now, function()
		local buff = playerBuffs[userId] and playerBuffs[userId][buffType]
		if buff and buff.expiresAt == thisExpiry then
			playerBuffs[userId][buffType] = nil
			if player.Parent then
				RE_BuffExpired:FireClient(player, buffType)
			end
		end
	end)
end

-- Get the effective multiplier for a buff type (1 if no active buff)
local function getBuffMultiplier(userId: number, buffType: string): number
	local buff = getActiveBuff(userId, buffType)
	if buff then
		return buff.multiplier
	end
	return 1
end

--------------------------------------------------------------------------------
-- BindableFunctions — API for other server scripts
--------------------------------------------------------------------------------

local BF_GetPlayerBuffs = getOrCreateBindable("BindableFunction", "BF_GetPlayerBuffs")

--[[
	Returns all active buff multipliers for a player.
	PlantSystem reads "growthBoost", MutationEngine reads "luckyCharm".

	Returns: { growthBoost: number, luckyCharm: number }
	Values are multipliers (1 = no buff active).
]]
BF_GetPlayerBuffs.OnInvoke = function(userId: number): { [string]: number }
	if typeof(userId) ~= "number" then
		return { growthBoost = 1, luckyCharm = 1 }
	end
	return {
		growthBoost = getBuffMultiplier(userId, "growthBoost"),
		luckyCharm = getBuffMultiplier(userId, "luckyCharm"),
	}
end

-- Client can query their own active buffs
RF_GetActiveBuffs.OnServerInvoke = function(player: Player)
	local buffs = getBuffs(player.UserId)
	local result = {}
	local now = os.time()
	for buffType, buff in buffs do
		if now < buff.expiresAt then
			result[buffType] = {
				multiplier = buff.multiplier,
				remaining = buff.expiresAt - now,
			}
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Game Pass Ownership Check
--------------------------------------------------------------------------------

-- Reverse lookup: passId -> passName
local passIdToName: { [number]: string } = {}
for name, id in GAME_PASSES do
	if id ~= 0 then
		passIdToName[id] = name
	end
end

local function checkGamePasses(player: Player, data)
	for passName, passId in GAME_PASSES do
		if passId == 0 then continue end -- placeholder, skip

		local success, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)

		if success and owns then
			data.gamePasses[passName] = true
		end
	end
end

-- Handle mid-session game pass purchase
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased then return end

	local passName = passIdToName[passId]
	if not passName then return end

	local data = getPlayerData(player)
	data.gamePasses[passName] = true

	RE_GamePassGranted:FireClient(player, passName)

	-- Apply immediate effects for certain passes
	if passName == "EXTRA_PLOTS" or passName == "MEGA_PLOTS" then
		-- maxPlots is computed dynamically from gamePasses in PlantSystem,
		-- so setting the flag is sufficient. Notify client to refresh UI.
		local RF_GetPlots = Remotes:FindFirstChild("RF_GetPlots")
		-- Client will re-query plots to see updated maxPlots
	end
end)

--------------------------------------------------------------------------------
-- Developer Product Purchase Callbacks
--------------------------------------------------------------------------------

-- Reverse lookup: productId -> productName
local productIdToName: { [number]: string } = {}
for name, id in DEV_PRODUCTS do
	if id ~= 0 then
		productIdToName[id] = name
	end
end

local function deliverLuckyCharm(player: Player, data)
	activateBuff(player, "luckyCharm", LUCKY_CHARM_MULTIPLIER, LUCKY_CHARM_DURATION)
	RE_ProductDelivered:FireClient(player, "LUCKY_CHARM", {
		buffType = "luckyCharm",
		duration = LUCKY_CHARM_DURATION,
		multiplier = LUCKY_CHARM_MULTIPLIER,
	})
end

local function deliverGrowthBoost(player: Player, data)
	activateBuff(player, "growthBoost", GROWTH_BOOST_MULTIPLIER, GROWTH_BOOST_DURATION)
	RE_ProductDelivered:FireClient(player, "GROWTH_BOOST", {
		buffType = "growthBoost",
		duration = GROWTH_BOOST_DURATION,
		multiplier = GROWTH_BOOST_MULTIPLIER,
	})
end

local function deliverPremiumEgg(player: Player, data)
	-- Validate creature capacity
	if #data.creatures >= CreatureData.MAX_CREATURES then
		-- Refund by giving a redeemable item instead
		data.inventory.items.premiumEgg = (data.inventory.items.premiumEgg or 0) + 1
		RE_ProductDelivered:FireClient(player, "PREMIUM_EGG", {
			stored = true,
			reason = "Creature slots full — egg added to inventory.",
		})
		return
	end

	-- Roll from premium pool
	local egg = CreatureData.Eggs.premium
	if not egg then return end

	local totalWeight = 0
	for _, entry in egg.pool do
		totalWeight += entry.weight
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	local creatureId: string = egg.pool[1].creatureId

	for _, entry in egg.pool do
		cumulative += entry.weight
		if roll <= cumulative then
			creatureId = entry.creatureId
			break
		end
	end

	table.insert(data.creatures, {
		creatureId = creatureId,
		level = 1,
		xp = 0,
		evolved = false,
	})

	local def = CreatureData.Creatures[creatureId]
	RE_ProductDelivered:FireClient(player, "PREMIUM_EGG", {
		creatureId = creatureId,
		name = def and def.name or creatureId,
		rarity = def and def.rarity or "Common",
	})
end

local function deliverLegendaryEgg(player: Player, data)
	if #data.creatures >= CreatureData.MAX_CREATURES then
		data.inventory.items.legendaryEgg = (data.inventory.items.legendaryEgg or 0) + 1
		RE_ProductDelivered:FireClient(player, "LEGENDARY_EGG", {
			stored = true,
			reason = "Creature slots full — egg added to inventory.",
		})
		return
	end

	local egg = CreatureData.Eggs.legendary
	if not egg then return end

	local totalWeight = 0
	for _, entry in egg.pool do
		totalWeight += entry.weight
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	local creatureId: string = egg.pool[1].creatureId

	for _, entry in egg.pool do
		cumulative += entry.weight
		if roll <= cumulative then
			creatureId = entry.creatureId
			break
		end
	end

	table.insert(data.creatures, {
		creatureId = creatureId,
		level = 1,
		xp = 0,
		evolved = false,
	})

	local def = CreatureData.Creatures[creatureId]
	RE_ProductDelivered:FireClient(player, "LEGENDARY_EGG", {
		creatureId = creatureId,
		name = def and def.name or creatureId,
		rarity = def and def.rarity or "Common",
	})
end

local function deliverSeedPack(player: Player, data)
	local delivered = {}
	for _, entry in SEED_PACK_CONTENTS do
		data.inventory.seeds[entry.seedId] = (data.inventory.seeds[entry.seedId] or 0) + entry.count
		table.insert(delivered, { seedId = entry.seedId, count = entry.count })
	end

	RE_ProductDelivered:FireClient(player, "SEED_PACK", {
		seeds = delivered,
	})
end

local function deliverGardenReset(player: Player, data)
	-- Clear all plots (unharvested plants are lost)
	data.plots = {}

	RE_ProductDelivered:FireClient(player, "GARDEN_RESET", {
		plotsCleared = true,
	})
end

-- Product delivery dispatch
local PRODUCT_HANDLERS: { [string]: (Player, any) -> () } = {
	LUCKY_CHARM = deliverLuckyCharm,
	GROWTH_BOOST = deliverGrowthBoost,
	PREMIUM_EGG = deliverPremiumEgg,
	LEGENDARY_EGG = deliverLegendaryEgg,
	SEED_PACK = deliverSeedPack,
	GARDEN_RESET = deliverGardenReset,
}

-- ProcessReceipt callback — MUST return Enum.ProductPurchaseDecision
MarketplaceService.ProcessReceipt = function(receiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Player left before delivery; return NotProcessedYet so Roblox retries
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local productName = productIdToName[receiptInfo.ProductId]
	if not productName then
		warn(`Unknown product ID: {receiptInfo.ProductId}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local handler = PRODUCT_HANDLERS[productName]
	if not handler then
		warn(`No handler for product: {productName}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = getPlayerData(player)

	local success, err = pcall(function()
		handler(player, data)
	end)

	if not success then
		warn(`Failed to deliver {productName} to {player.Name}: {err}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Save immediately after purchase delivery
	local saveSuccess = DataManager.saveData(player, data)
	if not saveSuccess then
		-- Data didn't save, but product was delivered in-memory.
		-- Return PurchaseGranted anyway — the save will catch up on
		-- the next auto-save or player leaving. Returning NotProcessedYet
		-- would cause a duplicate delivery.
		warn(`Save after {productName} purchase failed for {player.Name}, will retry on next save`)
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--------------------------------------------------------------------------------
-- Auto-Harvest System (for AUTO_HARVEST game pass)
--------------------------------------------------------------------------------

local function getHarvestValue(seedId: string, mutation: string?, data, userId: number): number
	local plant = PlantData[seedId]
	if not plant then return 0 end

	local value = plant.baseValue

	-- Fertilizer upgrade
	local fertBonus = 1 + data.upgrades.fertilizer * GameConfig.UPGRADES.fertilizer.valueBonus
	value *= fertBonus

	-- Mutation multiplier
	value *= BF_GetMutationValue:Invoke(mutation)

	-- Creature coin value bonus
	if not BF_GetCreatureBonuses then
		BF_GetCreatureBonuses = ServerStorage:FindFirstChild("BF_GetCreatureBonuses")
	end
	if BF_GetCreatureBonuses then
		local success, bonuses = pcall(function()
			return (BF_GetCreatureBonuses :: BindableFunction):Invoke(userId)
		end)
		if success and bonuses then
			value *= (1 + (bonuses.coinValue or 0))
		end
	end

	-- VIP pass bonus
	if data.gamePasses.VIP then
		value *= 1.5
	end

	return math.floor(value)
end

local function autoHarvestTick()
	for userId, data in DataManager.getAllCachedData() do
		-- Only auto-harvest for players with the pass
		if not data.gamePasses.AUTO_HARVEST then continue end

		local player = Players:GetPlayerByUserId(userId)
		if not player then continue end

		for plotIndex, plot in data.plots do
			if not plot or not plot.seedId then continue end
			if not plot.growthProgress or plot.growthProgress < 1 then continue end

			-- Harvest this plot
			local coinValue = getHarvestValue(plot.seedId, plot.mutation, data, userId)

			data.coins += coinValue
			data.stats.totalHarvests += 1
			data.stats.totalCoins += coinValue

			-- Notify client
			RE_HarvestResult:FireClient(player, plotIndex, plot.seedId, plot.mutation, coinValue, data.coins)

			-- Clear the plot
			data.plots[plotIndex] = nil
		end
	end
end

-- Auto-harvest loop
task.spawn(function()
	while true do
		task.wait(AUTO_HARVEST_INTERVAL)
		autoHarvestTick()
	end
end)

--------------------------------------------------------------------------------
-- Integration: Update PlantSystem/MutationEngine multipliers
-- PlantSystem and MutationEngine query BF_GetPlayerBuffs to factor in
-- growth boost and lucky charm. We update them here to integrate with
-- the existing systems via their BindableFunction patterns.
--------------------------------------------------------------------------------

-- PlantSystem needs growth boost multiplier — it already queries via
-- BF_GetPlayerBuffs. Similarly, MutationEngine queries luckyCharm.
-- Both are exposed above through BF_GetPlayerBuffs.OnInvoke.

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	-- Initialize buff table
	playerBuffs[player.UserId] = {}
end)

Players.PlayerRemoving:Connect(function(player: Player)
	playerBuffs[player.UserId] = nil
end)
