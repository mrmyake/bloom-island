-- CreatureSystem: Egg hatching, feeding, leveling, evolution, and passive bonuses.
-- All logic server-side. Exposes passive bonus totals via BindableFunctions
-- so PlantSystem and MutationEngine can query them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CreatureData = require(Shared.Config.CreatureData)
local PlantData = require(Shared.Config.PlantData)
local DataManager = require(script.Parent.DataManager)

-- AntiExploit validation
local BF_ValidateRemoteCall = ServerStorage:WaitForChild("BF_ValidateRemoteCall")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

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

local function getPlayerData(player: Player)
	return DataManager.getData(player.UserId)
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local RE_HatchEgg = getOrCreateRemote("RemoteEvent", "RE_HatchEgg")
local RE_FeedCreature = getOrCreateRemote("RemoteEvent", "RE_FeedCreature")
local RE_EvolveCreature = getOrCreateRemote("RemoteEvent", "RE_EvolveCreature")
local RE_ReleaseCreature = getOrCreateRemote("RemoteEvent", "RE_ReleaseCreature")

local RE_HatchResult = getOrCreateRemote("RemoteEvent", "RE_HatchResult")
local RE_FeedResult = getOrCreateRemote("RemoteEvent", "RE_FeedResult")
local RE_EvolveResult = getOrCreateRemote("RemoteEvent", "RE_EvolveResult")
local RE_ReleaseResult = getOrCreateRemote("RemoteEvent", "RE_ReleaseResult")
local RE_CreatureLevelUp = getOrCreateRemote("RemoteEvent", "RE_CreatureLevelUp")

local RF_GetCreatures = getOrCreateRemote("RemoteFunction", "RF_GetCreatures")

--------------------------------------------------------------------------------
-- Leveling Math
--------------------------------------------------------------------------------

local function xpForLevel(level: number): number
	if level <= 1 then return 0 end
	return math.floor(CreatureData.BASE_XP * level ^ CreatureData.XP_EXPONENT)
end

local function getLevelFromXP(totalXP: number): number
	for level = CreatureData.MAX_LEVEL, 1, -1 do
		if totalXP >= xpForLevel(level) then
			return level
		end
	end
	return 1
end

--------------------------------------------------------------------------------
-- Passive Bonus Calculation
--------------------------------------------------------------------------------

local function computePassiveBonuses(creatures: { any }): { [string]: number }
	local bonuses: { [string]: number } = {
		growthSpeed = 0,
		coinValue = 0,
		mutationLuck = 0,
		xpGain = 0,
	}

	for _, creature in creatures do
		local def = CreatureData.Creatures[creature.creatureId]
		if not def then continue end

		local amount = def.bonusAmount
		if creature.evolved then
			amount *= def.evolvedBonusMult
		end

		-- Scale bonus slightly with level (1x at level 1, up to 1.5x at max)
		local levelScale = 1 + (creature.level - 1) / (CreatureData.MAX_LEVEL - 1) * 0.5
		amount *= levelScale

		bonuses[def.bonusType] += amount
	end

	return bonuses
end

--------------------------------------------------------------------------------
-- Egg Hatching
--------------------------------------------------------------------------------

local function rollCreatureFromEgg(eggId: string): string?
	local egg = CreatureData.Eggs[eggId]
	if not egg then return nil end

	local totalWeight = 0
	for _, entry in egg.pool do
		totalWeight += entry.weight
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, entry in egg.pool do
		cumulative += entry.weight
		if roll <= cumulative then
			return entry.creatureId
		end
	end

	-- Fallback to first entry
	return egg.pool[1].creatureId
end

RE_HatchEgg.OnServerEvent:Connect(function(player: Player, eggId)
	if not BF_ValidateRemoteCall:Invoke(player.UserId, "RE_HatchEgg", { eggId }) then return end

	-- Validate types
	if typeof(eggId) ~= "string" then return end

	local data = getPlayerData(player)

	-- Validate egg exists
	local egg = CreatureData.Eggs[eggId]
	if not egg then return end

	-- Validate creature capacity
	if #data.creatures >= CreatureData.MAX_CREATURES then
		RE_HatchResult:FireClient(player, false, nil, "MAX_CREATURES")
		return
	end

	-- Validate coins
	if data.coins < egg.cost then
		RE_HatchResult:FireClient(player, false, nil, "NOT_ENOUGH_COINS")
		return
	end

	-- Deduct coins
	data.coins -= egg.cost

	-- Roll creature
	local creatureId = rollCreatureFromEgg(eggId)
	if not creatureId then
		-- Refund on failure (should never happen with valid data)
		data.coins += egg.cost
		RE_HatchResult:FireClient(player, false, nil, "ROLL_FAILED")
		return
	end

	-- Add creature to player data
	local newCreature = {
		creatureId = creatureId,
		level = 1,
		xp = 0,
		evolved = false,
	}
	table.insert(data.creatures, newCreature)

	local creatureDef = CreatureData.Creatures[creatureId]
	RE_HatchResult:FireClient(player, true, {
		creatureId = creatureId,
		name = creatureDef and creatureDef.name or creatureId,
		rarity = creatureDef and creatureDef.rarity or "Common",
		slotIndex = #data.creatures,
	}, nil)
end)

--------------------------------------------------------------------------------
-- Feeding (consumes seeds from inventory, grants XP)
--------------------------------------------------------------------------------

RE_FeedCreature.OnServerEvent:Connect(function(player: Player, creatureIndex, seedId)
	if not BF_ValidateRemoteCall:Invoke(player.UserId, "RE_FeedCreature", { creatureIndex, seedId }) then return end

	-- Validate types
	if typeof(creatureIndex) ~= "number" then return end
	if typeof(seedId) ~= "string" then return end
	if creatureIndex ~= math.floor(creatureIndex) then return end

	local data = getPlayerData(player)

	-- Validate creature exists
	if creatureIndex < 1 or creatureIndex > #data.creatures then return end
	local creature = data.creatures[creatureIndex]
	if not creature then return end

	-- Validate creature not at max level
	if creature.level >= CreatureData.MAX_LEVEL then
		RE_FeedResult:FireClient(player, false, creatureIndex, "MAX_LEVEL")
		return
	end

	-- Validate seed exists in config
	local plant = PlantData[seedId]
	if not plant then return end

	-- Validate player has the seed in inventory
	if not data.inventory.seeds[seedId] or data.inventory.seeds[seedId] <= 0 then
		RE_FeedResult:FireClient(player, false, creatureIndex, "NO_SEEDS")
		return
	end

	-- Consume seed
	data.inventory.seeds[seedId] -= 1
	if data.inventory.seeds[seedId] <= 0 then
		data.inventory.seeds[seedId] = nil
	end

	-- Calculate XP gained
	local baseXP = plant.baseValue * CreatureData.XP_PER_VALUE
	local tierMult = CreatureData.FEED_TIER_MULT[plant.tier] or 1

	-- Apply creature xpGain bonus from all creatures
	local bonuses = computePassiveBonuses(data.creatures)
	local xpMult = 1 + bonuses.xpGain

	local xpGained = math.floor(baseXP * tierMult * xpMult)
	local previousLevel = creature.level
	creature.xp += xpGained
	creature.level = getLevelFromXP(creature.xp)

	-- Clamp to max level
	if creature.level > CreatureData.MAX_LEVEL then
		creature.level = CreatureData.MAX_LEVEL
	end

	RE_FeedResult:FireClient(player, true, creatureIndex, nil, {
		xpGained = xpGained,
		totalXP = creature.xp,
		level = creature.level,
		seedId = seedId,
	})

	-- Fire level-up event if applicable
	if creature.level > previousLevel then
		local creatureDef = CreatureData.Creatures[creature.creatureId]
		RE_CreatureLevelUp:FireClient(player, creatureIndex, creature.level, {
			name = creatureDef and creatureDef.name or creature.creatureId,
			canEvolve = not creature.evolved
				and creatureDef ~= nil
				and creature.level >= creatureDef.evolveLevel,
		})
	end
end)

--------------------------------------------------------------------------------
-- Evolution
--------------------------------------------------------------------------------

RE_EvolveCreature.OnServerEvent:Connect(function(player: Player, creatureIndex)
	if not BF_ValidateRemoteCall:Invoke(player.UserId, "RE_EvolveCreature", { creatureIndex }) then return end

	-- Validate types
	if typeof(creatureIndex) ~= "number" then return end
	if creatureIndex ~= math.floor(creatureIndex) then return end

	local data = getPlayerData(player)

	-- Validate creature exists
	if creatureIndex < 1 or creatureIndex > #data.creatures then return end
	local creature = data.creatures[creatureIndex]
	if not creature then return end

	-- Validate not already evolved
	if creature.evolved then
		RE_EvolveResult:FireClient(player, false, creatureIndex, "ALREADY_EVOLVED")
		return
	end

	-- Validate creature definition
	local creatureDef = CreatureData.Creatures[creature.creatureId]
	if not creatureDef then return end

	-- Validate level requirement
	if creature.level < creatureDef.evolveLevel then
		RE_EvolveResult:FireClient(player, false, creatureIndex, "LEVEL_TOO_LOW")
		return
	end

	-- Validate coin cost
	local evolveCost = creatureDef.evolveLevel * CreatureData.EVOLVE_COIN_COST_MULT
	if data.coins < evolveCost then
		RE_EvolveResult:FireClient(player, false, creatureIndex, "NOT_ENOUGH_COINS")
		return
	end

	-- Deduct coins and evolve
	data.coins -= evolveCost
	creature.evolved = true

	RE_EvolveResult:FireClient(player, true, creatureIndex, nil, {
		evolvedName = creatureDef.evolvedName,
		creatureId = creature.creatureId,
		coins = data.coins,
	})

	-- Award season pass XP for evolution
	local seasonXPEvent = ServerStorage:FindFirstChild("BE_SeasonXPEvent")
	if seasonXPEvent then
		(seasonXPEvent :: BindableEvent):Fire(player.UserId, 100, "creatureEvolve")
	end
end)

--------------------------------------------------------------------------------
-- Release (remove a creature, freeing a slot)
--------------------------------------------------------------------------------

RE_ReleaseCreature.OnServerEvent:Connect(function(player: Player, creatureIndex)
	if not BF_ValidateRemoteCall:Invoke(player.UserId, "RE_ReleaseCreature", { creatureIndex }) then return end

	-- Validate types
	if typeof(creatureIndex) ~= "number" then return end
	if creatureIndex ~= math.floor(creatureIndex) then return end

	local data = getPlayerData(player)

	-- Validate creature exists
	if creatureIndex < 1 or creatureIndex > #data.creatures then return end
	local creature = data.creatures[creatureIndex]
	if not creature then return end

	-- Give a small coin refund based on level
	local creatureDef = CreatureData.Creatures[creature.creatureId]
	local refund = 0
	if creatureDef then
		local eggCost = 0
		-- Find cheapest egg that contains this creature for refund basis
		for _, egg in CreatureData.Eggs do
			for _, entry in egg.pool do
				if entry.creatureId == creature.creatureId then
					if eggCost == 0 or egg.cost < eggCost then
						eggCost = egg.cost
					end
				end
			end
		end
		-- Refund 25% of egg cost + 10 coins per level
		refund = math.floor(eggCost * 0.25) + creature.level * 10
	end

	table.remove(data.creatures, creatureIndex)
	data.coins += refund

	RE_ReleaseResult:FireClient(player, true, creatureIndex, refund, data.coins)
end)

--------------------------------------------------------------------------------
-- Data Request
--------------------------------------------------------------------------------

RF_GetCreatures.OnServerInvoke = function(player: Player)
	local data = getPlayerData(player)

	-- Build enriched creature list for client display
	local result = {}
	for i, creature in data.creatures do
		local def = CreatureData.Creatures[creature.creatureId]
		local xpCurrent = creature.xp
		local xpNext = xpForLevel(creature.level + 1)
		local xpPrev = xpForLevel(creature.level)

		table.insert(result, {
			creatureId = creature.creatureId,
			name = if creature.evolved and def then def.evolvedName else (def and def.name or creature.creatureId),
			rarity = def and def.rarity or "Common",
			level = creature.level,
			xp = xpCurrent,
			xpForNext = if creature.level < CreatureData.MAX_LEVEL then xpNext else xpCurrent,
			xpForCurrent = xpPrev,
			evolved = creature.evolved,
			bonusType = def and def.bonusType or "growthSpeed",
			canEvolve = not creature.evolved and def ~= nil and creature.level >= def.evolveLevel,
			evolveCost = if def then def.evolveLevel * CreatureData.EVOLVE_COIN_COST_MULT else 0,
		})
	end

	local bonuses = computePassiveBonuses(data.creatures)
	return result, bonuses, CreatureData.MAX_CREATURES
end

--------------------------------------------------------------------------------
-- BindableFunctions — API for other server scripts
--------------------------------------------------------------------------------

local BF_GetCreatureBonuses = getOrCreateBindable("BindableFunction", "BF_GetCreatureBonuses")

--[[
	Returns the combined passive bonuses for a player's creatures.
	Other scripts (PlantSystem, MutationEngine) call this to apply bonuses.

	Returns: { growthSpeed: number, coinValue: number, mutationLuck: number, xpGain: number }
	Values are additive multiplier offsets (e.g. 0.15 means +15%).
]]
BF_GetCreatureBonuses.OnInvoke = function(userId: number): { [string]: number }
	if typeof(userId) ~= "number" then
		return { growthSpeed = 0, coinValue = 0, mutationLuck = 0, xpGain = 0 }
	end

	local data = DataManager.getData(userId)
	if not data then
		return { growthSpeed = 0, coinValue = 0, mutationLuck = 0, xpGain = 0 }
	end

	return computePassiveBonuses(data.creatures)
end

