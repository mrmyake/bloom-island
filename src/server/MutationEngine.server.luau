-- MutationEngine: Centralized mutation rolling, pity tracking, discovery journal,
-- and server-wide mutation bonus events.
-- Exposes API to other server scripts via BindableFunctions in ServerStorage.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local MutationData = require(Shared.Config.MutationData)
local GameConfig = require(Shared.Config.GameConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Roll order: rarest to most common so a rarer hit wins
local ROLL_ORDER = { "secret", "mythical", "celestial", "cosmic", "rainbow", "golden" }

-- Pity: after this many consecutive no-mutation harvests, odds start ramping
local PITY_THRESHOLD = 10
-- Each harvest past the threshold adds this flat bonus to every tier's chance
local PITY_BONUS_PER_HARVEST = 0.005
-- Maximum pity multiplier applied to base chances (prevents guaranteed legendaries)
local MAX_PITY_MULT = 3.0

-- Cap any single tier's effective chance so rarity still feels meaningful
local MAX_TIER_CHANCE = 0.50

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Per-player pity counters: UserId -> consecutive harvests without a mutation
local pityCounters: { [number]: number } = {}

-- Per-player discovery journal: UserId -> { [mutationId] = firstFoundTimestamp }
local discoveryJournals: { [number]: { [string]: number } } = {}

-- Server-wide temporary mutation bonus (e.g. from events or dev products)
-- { multiplier: number, expiresAt: number }
local serverBonus: { multiplier: number, expiresAt: number }? = nil

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

local function getCurrentWeather(): string
	local weatherValue = ReplicatedStorage:FindFirstChild("CurrentWeather")
	if weatherValue and weatherValue:IsA("StringValue") then
		return weatherValue.Value
	end
	return "sunny"
end

local function getWeatherMutationMult(): number
	return GameConfig.WEATHER_MUTATION_MULT[getCurrentWeather()] or 1
end

local function getServerBonusMult(): number
	if serverBonus and os.time() < serverBonus.expiresAt then
		return serverBonus.multiplier
	end
	-- Expired — clear it
	if serverBonus then
		serverBonus = nil
	end
	return 1
end

local function getPityMult(userId: number): number
	local count = pityCounters[userId] or 0
	if count <= PITY_THRESHOLD then
		return 1
	end
	local overThreshold = count - PITY_THRESHOLD
	return math.min(1 + overThreshold * PITY_BONUS_PER_HARVEST / 0.10, MAX_PITY_MULT)
end

local function getCreatureMutationLuck(userId: number): number
	local BF_GetCreatureBonuses = ServerStorage:FindFirstChild("BF_GetCreatureBonuses")
	if not BF_GetCreatureBonuses then return 0 end
	local success, bonuses = pcall(function()
		return BF_GetCreatureBonuses:Invoke(userId)
	end)
	if success and bonuses then
		return bonuses.mutationLuck or 0
	end
	return 0
end

local function getLuckyCharmMult(userId: number): number
	local BF_GetPlayerBuffs = ServerStorage:FindFirstChild("BF_GetPlayerBuffs")
	if not BF_GetPlayerBuffs then return 1 end
	local success, buffs = pcall(function()
		return BF_GetPlayerBuffs:Invoke(userId)
	end)
	if success and buffs and buffs.luckyCharm then
		return buffs.luckyCharm
	end
	return 1
end

--------------------------------------------------------------------------------
-- Core: Roll Mutation
--------------------------------------------------------------------------------

--[[
	Rolls for a mutation on a finished plant.

	Parameters:
		seedId          - which plant was grown
		greenhouseLevel - player's greenhouse upgrade level
		userId          - for pity tracking

	Returns:
		mutationId: string?  - nil if no mutation
]]
local function rollMutation(seedId: string, greenhouseLevel: number, userId: number): string?
	local plant = PlantData[seedId]
	if not plant then return nil end

	local weatherMult = getWeatherMutationMult()
	local greenhouseBonus = 1 + greenhouseLevel * GameConfig.UPGRADES.greenhouse.mutationBonus
	local serverMult = getServerBonusMult()
	local pityMult = getPityMult(userId)

	-- Per-plant modifier normalized against Common base (0.08)
	local plantFactor = plant.mutationChance / 0.08

	local creatureLuck = 1 + getCreatureMutationLuck(userId)
	local luckyCharm = getLuckyCharmMult(userId)

	local combinedMult = weatherMult * greenhouseBonus * serverMult * pityMult * plantFactor * creatureLuck * luckyCharm

	for _, mutationId in ROLL_ORDER do
		local mutData = MutationData[mutationId]
		if not mutData then continue end

		local chance = math.min(mutData.baseChance * combinedMult, MAX_TIER_CHANCE)

		if math.random() <= chance then
			-- Reset pity on any mutation hit
			pityCounters[userId] = 0

			-- Record discovery
			if not discoveryJournals[userId] then
				discoveryJournals[userId] = {}
			end
			if not discoveryJournals[userId][mutationId] then
				discoveryJournals[userId][mutationId] = os.time()
			end

			return mutationId
		end
	end

	-- No mutation — increment pity
	pityCounters[userId] = (pityCounters[userId] or 0) + 1
	return nil
end

--------------------------------------------------------------------------------
-- Core: Compute Harvest Value with Mutation
--------------------------------------------------------------------------------

local function getMutationValueMultiplier(mutationId: string?): number
	if not mutationId then return 1 end
	local mutData = MutationData[mutationId]
	if not mutData then return 1 end
	return mutData.valueMultiplier
end

--------------------------------------------------------------------------------
-- Core: Discovery Journal
--------------------------------------------------------------------------------

local function getDiscoveryJournal(userId: number): { [string]: number }
	return discoveryJournals[userId] or {}
end

local function isFirstDiscovery(userId: number, mutationId: string): boolean
	local journal = discoveryJournals[userId]
	if not journal then return true end
	return journal[mutationId] == nil
end

local function getTotalDiscovered(userId: number): number
	local journal = discoveryJournals[userId]
	if not journal then return 0 end
	local count = 0
	for _ in journal do
		count += 1
	end
	return count
end

--------------------------------------------------------------------------------
-- Core: Server Bonus Events
--------------------------------------------------------------------------------

local function setServerBonus(multiplier: number, durationSeconds: number)
	serverBonus = {
		multiplier = multiplier,
		expiresAt = os.time() + durationSeconds,
	}
end

local function getServerBonus(): (number, number)
	if serverBonus and os.time() < serverBonus.expiresAt then
		return serverBonus.multiplier, serverBonus.expiresAt - os.time()
	end
	return 1, 0
end

--------------------------------------------------------------------------------
-- Core: Pity
--------------------------------------------------------------------------------

local function getPityCount(userId: number): number
	return pityCounters[userId] or 0
end

local function resetPity(userId: number)
	pityCounters[userId] = 0
end

--------------------------------------------------------------------------------
-- Core: Odds Preview (returns effective chances for UI display tiers only,
-- never exposes hidden/"secret" tier or exact base rates)
--------------------------------------------------------------------------------

local VISIBLE_TIERS = { "golden", "rainbow", "cosmic", "celestial", "mythical" }

local function getEffectiveOdds(greenhouseLevel: number, userId: number): { [string]: string }
	local weatherMult = getWeatherMutationMult()
	local greenhouseBonus = 1 + greenhouseLevel * GameConfig.UPGRADES.greenhouse.mutationBonus
	local serverMult = getServerBonusMult()
	local pityMult = getPityMult(userId)
	local creatureLuck = 1 + getCreatureMutationLuck(userId)
	local luckyCharm = getLuckyCharmMult(userId)
	local combinedMult = weatherMult * greenhouseBonus * serverMult * pityMult * creatureLuck * luckyCharm

	-- Return vague tier labels instead of exact numbers
	local function chanceToLabel(chance: number): string
		if chance >= 0.08 then return "High" end
		if chance >= 0.02 then return "Medium" end
		if chance >= 0.005 then return "Low" end
		if chance >= 0.001 then return "Very Low" end
		return "Extremely Rare"
	end

	local result: { [string]: string } = {}
	for _, mutationId in VISIBLE_TIERS do
		local mutData = MutationData[mutationId]
		if not mutData then continue end
		local effective = math.min(mutData.baseChance * combinedMult, MAX_TIER_CHANCE)
		result[mutationId] = chanceToLabel(effective)
	end
	return result
end

--------------------------------------------------------------------------------
-- BindableFunctions — API for other server scripts
--------------------------------------------------------------------------------

local BF_RollMutation = getOrCreateBindable("BindableFunction", "BF_RollMutation")
local BF_GetMutationValue = getOrCreateBindable("BindableFunction", "BF_GetMutationValue")
local BF_GetDiscoveryJournal = getOrCreateBindable("BindableFunction", "BF_GetDiscoveryJournal")
local BF_IsFirstDiscovery = getOrCreateBindable("BindableFunction", "BF_IsFirstDiscovery")
local BF_GetEffectiveOdds = getOrCreateBindable("BindableFunction", "BF_GetEffectiveOdds")
local BF_GetPityCount = getOrCreateBindable("BindableFunction", "BF_GetPityCount")
local BF_SetServerBonus = getOrCreateBindable("BindableFunction", "BF_SetServerBonus")
local BF_GetServerBonus = getOrCreateBindable("BindableFunction", "BF_GetServerBonus")

BF_RollMutation.OnInvoke = function(seedId: string, greenhouseLevel: number, userId: number): string?
	if typeof(seedId) ~= "string" then return nil end
	if typeof(greenhouseLevel) ~= "number" then return nil end
	if typeof(userId) ~= "number" then return nil end
	return rollMutation(seedId, greenhouseLevel, userId)
end

BF_GetMutationValue.OnInvoke = function(mutationId: string?): number
	return getMutationValueMultiplier(mutationId)
end

BF_GetDiscoveryJournal.OnInvoke = function(userId: number): { [string]: number }
	if typeof(userId) ~= "number" then return {} end
	return getDiscoveryJournal(userId)
end

BF_IsFirstDiscovery.OnInvoke = function(userId: number, mutationId: string): boolean
	if typeof(userId) ~= "number" then return false end
	if typeof(mutationId) ~= "string" then return false end
	return isFirstDiscovery(userId, mutationId)
end

BF_GetEffectiveOdds.OnInvoke = function(greenhouseLevel: number, userId: number): { [string]: string }
	if typeof(greenhouseLevel) ~= "number" then return {} end
	if typeof(userId) ~= "number" then return {} end
	return getEffectiveOdds(greenhouseLevel, userId)
end

BF_GetPityCount.OnInvoke = function(userId: number): number
	if typeof(userId) ~= "number" then return 0 end
	return getPityCount(userId)
end

BF_SetServerBonus.OnInvoke = function(multiplier: number, durationSeconds: number): boolean
	if typeof(multiplier) ~= "number" then return false end
	if typeof(durationSeconds) ~= "number" then return false end
	if multiplier < 1 or multiplier > 10 then return false end
	if durationSeconds < 1 or durationSeconds > 3600 then return false end
	setServerBonus(multiplier, durationSeconds)
	return true
end

BF_GetServerBonus.OnInvoke = function(): (number, number)
	return getServerBonus()
end

--------------------------------------------------------------------------------
-- RemoteFunction — client can request their own odds preview and journal
--------------------------------------------------------------------------------

local RF_GetMutationOdds = getOrCreateRemote("RemoteFunction", "RF_GetMutationOdds")
local RF_GetDiscoveries = getOrCreateRemote("RemoteFunction", "RF_GetDiscoveries")

RF_GetMutationOdds.OnServerInvoke = function(player: Player, greenhouseLevel: number)
	-- Don't trust client-sent greenhouse level; read from data if available
	-- For now, accept the parameter (PlantSystem owns the data cache)
	if typeof(greenhouseLevel) ~= "number" then return {} end
	return getEffectiveOdds(greenhouseLevel, player.UserId)
end

RF_GetDiscoveries.OnServerInvoke = function(player: Player)
	local journal = getDiscoveryJournal(player.UserId)
	-- Return only visible tiers + total count
	local result = {}
	for mutationId, timestamp in journal do
		local mutData = MutationData[mutationId]
		if mutData and mutationId ~= "secret" then
			result[mutationId] = {
				name = mutData.name,
				rarity = mutData.rarity,
				discoveredAt = timestamp,
			}
		elseif mutationId == "secret" then
			-- Reveal existence but not details
			result[mutationId] = {
				name = "???",
				rarity = "???",
				discoveredAt = timestamp,
			}
		end
	end
	return result, getTotalDiscovered(player.UserId)
end

--------------------------------------------------------------------------------
-- Player Lifecycle — clean up state on leave
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player: Player)
	-- Pity and journal are ephemeral per-session for now.
	-- To persist across sessions, PlantSystem/DataManager would save these
	-- fields in PlayerData and pass them back on load.
	pityCounters[player.UserId] = nil
	discoveryJournals[player.UserId] = nil
end)
