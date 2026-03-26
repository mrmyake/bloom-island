-- PlantSystem: Handles planting, growth tracking, mutation rolling, and harvesting
-- All logic runs server-side; clients communicate via RemoteEvents

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local GameConfig = require(Shared.Config.GameConfig)
local DataManager = require(script.Parent.DataManager)

-- MutationEngine API (exposed via BindableFunctions in ServerStorage)
local BF_RollMutation = ServerStorage:WaitForChild("BF_RollMutation")
local BF_GetMutationValue = ServerStorage:WaitForChild("BF_GetMutationValue")

-- CreatureSystem API
local BF_GetCreatureBonuses = ServerStorage:WaitForChild("BF_GetCreatureBonuses")

-- MonetizationHandler API (per-player timed buffs)
local BF_GetPlayerBuffs = ServerStorage:WaitForChild("BF_GetPlayerBuffs")

-- AntiExploit validation
local BF_ValidateRemoteCall = ServerStorage:WaitForChild("BF_ValidateRemoteCall")

-- Create remote events/functions under the Remotes folder
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function getOrCreateRemote(className: string, name: string): Instance
	local remote = Remotes:FindFirstChild(name)
	if not remote then
		remote = Instance.new(className)
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end

local RE_PlantSeed = getOrCreateRemote("RemoteEvent", "RE_PlantSeed")
local RE_HarvestPlant = getOrCreateRemote("RemoteEvent", "RE_HarvestPlant")
local RE_PlotUpdated = getOrCreateRemote("RemoteEvent", "RE_PlotUpdated")
local RE_PlantGrown = getOrCreateRemote("RemoteEvent", "RE_PlantGrown")
local RE_MutationRolled = getOrCreateRemote("RemoteEvent", "RE_MutationRolled")
local RE_HarvestResult = getOrCreateRemote("RemoteEvent", "RE_HarvestResult")
local RF_GetPlots = getOrCreateRemote("RemoteFunction", "RF_GetPlots")

-- Active weather state (set by WeatherSystem, read here)
-- WeatherSystem writes to a StringValue in ReplicatedStorage
local weatherValue = ReplicatedStorage:FindFirstChild("CurrentWeather")

local function getCurrentWeather(): string
	if weatherValue and weatherValue:IsA("StringValue") then
		return weatherValue.Value
	end
	return "sunny"
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getPlayerData(player: Player)
	return DataManager.getData(player.UserId)
end

local function getMaxPlots(data): number
	local base = GameConfig.MAX_PLOTS_BASE
	local upgradeSlots = data.upgrades.extraSlots * GameConfig.UPGRADES.extraSlots.slotsPerLevel
	local passSlots = 0
	if data.gamePasses.EXTRA_PLOTS then
		passSlots += 4
	end
	if data.gamePasses.MEGA_PLOTS then
		passSlots += 8
	end
	return base + upgradeSlots + passSlots
end

local function getCreatureBonuses(userId: number): { [string]: number }
	local success, bonuses = pcall(function()
		return BF_GetCreatureBonuses:Invoke(userId)
	end)
	if success and bonuses then
		return bonuses
	end
	return { growthSpeed = 0, coinValue = 0, mutationLuck = 0, xpGain = 0 }
end

local function getPlayerBuffMultiplier(userId: number, buffType: string): number
	local success, buffs = pcall(function()
		return BF_GetPlayerBuffs:Invoke(userId)
	end)
	if success and buffs and buffs[buffType] then
		return buffs[buffType]
	end
	return 1
end

local function getGrowthMultiplier(data, userId: number): number
	local weatherMult = GameConfig.WEATHER_GROWTH_MULT[getCurrentWeather()] or 1
	local waterBonus = 1 + data.upgrades.water * GameConfig.UPGRADES.water.growSpeedBonus
	local creatureBonus = 1 + getCreatureBonuses(userId).growthSpeed
	local growthBoost = getPlayerBuffMultiplier(userId, "growthBoost")
	return weatherMult * waterBonus * creatureBonus * growthBoost
end

local function getHarvestValue(seedId: string, mutation: string?, data, userId: number): number
	local plant = PlantData[seedId]
	if not plant then return 0 end

	local value = plant.baseValue

	-- Fertilizer upgrade bonus
	local fertBonus = 1 + data.upgrades.fertilizer * GameConfig.UPGRADES.fertilizer.valueBonus
	value *= fertBonus

	-- Mutation multiplier (delegated to MutationEngine)
	value *= BF_GetMutationValue:Invoke(mutation)

	-- Creature coin value bonus
	value *= (1 + getCreatureBonuses(userId).coinValue)

	-- VIP pass bonus
	if data.gamePasses.VIP then
		value *= 1.5
	end

	return math.floor(value)
end

--------------------------------------------------------------------------------
-- Growth Tick
--------------------------------------------------------------------------------

local GROWTH_TICK_INTERVAL = 1 -- seconds

local function updateGrowth()
	local now = os.time()

	for userId, data in DataManager.getAllCachedData() do
		local player = Players:GetPlayerByUserId(userId)
		if not player then continue end

		for plotIndex, plot in data.plots do
			if not plot or not plot.seedId then continue end
			if plot.growthProgress >= 1 then continue end

			local plant = PlantData[plot.seedId]
			if not plant then continue end

			local elapsed = now - plot.plantedAt
			local effectiveGrowTime = plant.growTime / getGrowthMultiplier(data, userId)
			local progress = math.clamp(elapsed / effectiveGrowTime, 0, 1)
			local previousProgress = plot.growthProgress

			plot.growthProgress = progress

			-- Plant just finished growing
			if previousProgress < 1 and progress >= 1 then
				local mutation = BF_RollMutation:Invoke(plot.seedId, data.upgrades.greenhouse, userId)
				plot.mutation = mutation

				RE_PlantGrown:FireClient(player, plotIndex, plot.seedId)

				if mutation then
					-- Track rare finds
					data.stats.rareFinds += 1
					RE_MutationRolled:FireClient(player, plotIndex, mutation)

					-- Broadcast rare mutation discoveries to all servers
					local mutDiscovery = ServerStorage:FindFirstChild("BE_MutationDiscovery")
					if mutDiscovery then
						(mutDiscovery :: BindableEvent):Fire(player.Name, plot.seedId, mutation)
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Planting
--------------------------------------------------------------------------------

RE_PlantSeed.OnServerEvent:Connect(function(player: Player, plotIndex, seedId)
	-- Anti-exploit rate limit + sanity check
	if not BF_ValidateRemoteCall:Invoke(player.UserId, "RE_PlantSeed", { plotIndex, seedId }) then return end

	-- Validate types
	if typeof(plotIndex) ~= "number" then return end
	if typeof(seedId) ~= "string" then return end

	-- Validate integer plot index
	if plotIndex ~= math.floor(plotIndex) then return end

	local data = getPlayerData(player)
	local maxPlots = getMaxPlots(data)

	-- Validate range
	if plotIndex < 1 or plotIndex > maxPlots then return end

	-- Validate plot is empty
	if data.plots[plotIndex] and data.plots[plotIndex].seedId then return end

	-- Validate seed exists
	local plant = PlantData[seedId]
	if not plant then return end

	-- Check if player can afford it (seeds from inventory or buy with coins)
	local hasInInventory = data.inventory.seeds[seedId] and data.inventory.seeds[seedId] > 0
	if hasInInventory then
		data.inventory.seeds[seedId] -= 1
		if data.inventory.seeds[seedId] <= 0 then
			data.inventory.seeds[seedId] = nil
		end
	else
		if data.coins < plant.cost then return end
		data.coins -= plant.cost
	end

	-- Plant the seed
	data.plots[plotIndex] = {
		seedId = seedId,
		plantedAt = os.time(),
		mutation = nil,
		growthProgress = 0,
	}

	RE_PlotUpdated:FireClient(player, plotIndex, data.plots[plotIndex], data.coins)
end)

--------------------------------------------------------------------------------
-- Harvesting
--------------------------------------------------------------------------------

RE_HarvestPlant.OnServerEvent:Connect(function(player: Player, plotIndex)
	-- Anti-exploit rate limit + sanity check
	if not BF_ValidateRemoteCall:Invoke(player.UserId, "RE_HarvestPlant", { plotIndex }) then return end

	-- Validate types
	if typeof(plotIndex) ~= "number" then return end
	if plotIndex ~= math.floor(plotIndex) then return end

	local data = getPlayerData(player)
	local maxPlots = getMaxPlots(data)

	-- Validate range
	if plotIndex < 1 or plotIndex > maxPlots then return end

	-- Validate plot has a plant
	local plot = data.plots[plotIndex]
	if not plot or not plot.seedId then return end

	-- Validate plant is fully grown
	if plot.growthProgress < 1 then return end

	-- Calculate harvest value
	local coinValue = getHarvestValue(plot.seedId, plot.mutation, data, player.UserId)

	-- Award coins
	data.coins += coinValue
	data.stats.totalHarvests += 1
	data.stats.totalCoins += coinValue

	-- Send result to client before clearing
	RE_HarvestResult:FireClient(player, plotIndex, plot.seedId, plot.mutation, coinValue, data.coins)

	-- Award season pass XP
	local seasonXPEvent = ServerStorage:FindFirstChild("BE_SeasonXPEvent")
	if seasonXPEvent then
		local xpAmount = 10 -- base harvest XP
		if plot.mutation then
			xpAmount += 50 -- mutation bonus
		end
		(seasonXPEvent :: BindableEvent):Fire(player.UserId, xpAmount, "harvest")
	end

	-- Clear the plot
	data.plots[plotIndex] = nil
end)

--------------------------------------------------------------------------------
-- Data Request (client asks for current plot state)
--------------------------------------------------------------------------------

RF_GetPlots.OnServerInvoke = function(player: Player)
	local data = getPlayerData(player)
	return data.plots, data.coins, getMaxPlots(data)
end

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

-- Player lifecycle (data load/save/auto-save) handled by GameInit.server.luau

--------------------------------------------------------------------------------
-- Main Growth Loop
--------------------------------------------------------------------------------

local elapsed = 0
RunService.Heartbeat:Connect(function(dt: number)
	elapsed += dt
	if elapsed >= GROWTH_TICK_INTERVAL then
		elapsed -= GROWTH_TICK_INTERVAL
		updateGrowth()
	end
end)
