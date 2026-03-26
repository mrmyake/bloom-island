-- SeasonalPass: Free + premium season pass with 30 tiers, monthly reset.
-- Tracks XP from harvests, trades, gifts, visits, and evolutions.
-- Exposes a BindableFunction for other server scripts to award XP.
-- Handles premium purchase via MarketplaceService and reward claiming.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SeasonPassData = require(Shared.Config.SeasonPassData)

-- AntiExploit validation
local BF_ValidateRemoteCall = ServerStorage:WaitForChild("BF_ValidateRemoteCall")
local CreatureData = require(Shared.Config.CreatureData)
local DataManager = require(script.Parent.DataManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local MAX_TIER = SeasonPassData.MAX_TIER
local TIERS = SeasonPassData.Tiers
local XP_SOURCES = SeasonPassData.XP_SOURCES
local PREMIUM_PASS_ID = SeasonPassData.PREMIUM_PASS_ID

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

-- Remotes
local RE_ClaimSeasonReward = getOrCreateRemote("RemoteEvent", "RE_ClaimSeasonReward")
local RE_ClaimResult = getOrCreateRemote("RemoteEvent", "RE_ClaimResult")
local RE_SeasonXPGained = getOrCreateRemote("RemoteEvent", "RE_SeasonXPGained")
local RE_SeasonTierUp = getOrCreateRemote("RemoteEvent", "RE_SeasonTierUp")
local RE_SeasonPassPurchased = getOrCreateRemote("RemoteEvent", "RE_SeasonPassPurchased")
local RF_GetSeasonPassStatus = getOrCreateRemote("RemoteFunction", "RF_GetSeasonPassStatus")

-- BindableFunction for other server scripts to award XP
local BF_AwardSeasonXP = getOrCreateBindable("BindableFunction", "BF_AwardSeasonXP")

-- MonetizationHandler buff BindableFunction (for boost rewards)
-- Lazy-loaded since it may not exist yet at startup
local BF_GetPlayerBuffs: BindableFunction? = nil

local function getPlayerData(player: Player)
	return DataManager.getData(player.UserId)
end

--------------------------------------------------------------------------------
-- Season ID (monthly reset)
--------------------------------------------------------------------------------

local function getCurrentSeasonId(): string
	local date = os.date("!*t", os.time())
	return string.format("%04d-%02d", date.year, date.month)
end

local function ensureCurrentSeason(data)
	if not data.seasonPass then
		data.seasonPass = {
			tier = 0,
			premium = false,
			xp = 0,
			seasonId = "",
			claimedFree = {},
			claimedPremium = {},
		}
	end

	local currentSeason = getCurrentSeasonId()
	if data.seasonPass.seasonId ~= currentSeason then
		-- New season — reset progress, keep premium status for this month
		-- (Premium is per-season purchase, so reset it too)
		data.seasonPass.tier = 0
		data.seasonPass.xp = 0
		data.seasonPass.seasonId = currentSeason
		data.seasonPass.claimedFree = {}
		data.seasonPass.claimedPremium = {}
		data.seasonPass.premium = false
	end
end

--------------------------------------------------------------------------------
-- XP / Tier Math
--------------------------------------------------------------------------------

local function xpForTier(tier: number): number
	if tier <= 0 then return 0 end
	return math.floor(SeasonPassData.BASE_XP_PER_TIER * tier ^ SeasonPassData.XP_SCALE)
end

-- Total cumulative XP needed to reach a tier
local function cumulativeXPForTier(tier: number): number
	local total = 0
	for t = 1, tier do
		total += xpForTier(t)
	end
	return total
end

-- Compute tier from cumulative XP
local function tierFromXP(totalXP: number): number
	local cumulative = 0
	for t = 1, MAX_TIER do
		cumulative += xpForTier(t)
		if totalXP < cumulative then
			return t - 1
		end
	end
	return MAX_TIER
end

--------------------------------------------------------------------------------
-- Award XP
--------------------------------------------------------------------------------

local function awardXP(player: Player, amount: number, source: string)
	local data = getPlayerData(player)
	ensureCurrentSeason(data)

	if data.seasonPass.tier >= MAX_TIER then
		-- Already max tier, but still track XP
		data.seasonPass.xp += amount
		return
	end

	local previousTier = data.seasonPass.tier
	data.seasonPass.xp += amount
	local newTier = tierFromXP(data.seasonPass.xp)

	-- Cap at max
	if newTier > MAX_TIER then
		newTier = MAX_TIER
	end

	data.seasonPass.tier = newTier

	-- Notify client of XP gain
	RE_SeasonXPGained:FireClient(player, {
		xpGained = amount,
		source = source,
		totalXP = data.seasonPass.xp,
		currentTier = newTier,
		xpForNextTier = if newTier < MAX_TIER then cumulativeXPForTier(newTier + 1) else data.seasonPass.xp,
		xpForCurrentTier = cumulativeXPForTier(newTier),
	})

	-- Notify tier-ups
	if newTier > previousTier then
		for t = previousTier + 1, newTier do
			local tierData = TIERS[t]
			local hasFreePending = tierData and not data.seasonPass.claimedFree[tostring(t)]
			local hasPremiumPending = data.seasonPass.premium and tierData and not data.seasonPass.claimedPremium[tostring(t)]

			RE_SeasonTierUp:FireClient(player, {
				tier = t,
				hasFreePending = hasFreePending,
				hasPremiumPending = hasPremiumPending,
			})
		end
	end
end

--------------------------------------------------------------------------------
-- BindableFunction: Other scripts award season XP
--------------------------------------------------------------------------------

BF_AwardSeasonXP.OnInvoke = function(userId: number, amount: number, source: string): boolean
	if typeof(userId) ~= "number" then return false end
	if typeof(amount) ~= "number" or amount <= 0 then return false end
	if typeof(source) ~= "string" then return false end

	local player = Players:GetPlayerByUserId(userId)
	if not player then return false end

	awardXP(player, amount, source)
	return true
end

--------------------------------------------------------------------------------
-- Reward Delivery
--------------------------------------------------------------------------------

local function deliverReward(player: Player, data, reward): (boolean, string?)
	if reward.type == "coins" then
		data.coins += reward.amount
		return true, nil

	elseif reward.type == "seeds" then
		data.inventory.seeds[reward.seedId] = (data.inventory.seeds[reward.seedId] or 0) + reward.amount
		return true, nil

	elseif reward.type == "creature_egg" then
		-- Hatch from the specified egg pool
		local egg = CreatureData.Eggs[reward.eggId]
		if not egg then return false, "INVALID_EGG" end

		if #data.creatures >= CreatureData.MAX_CREATURES then
			-- Store as inventory item for later hatching
			local itemKey = `egg_{reward.eggId}`
			data.inventory.items[itemKey] = (data.inventory.items[itemKey] or 0) + 1
			return true, nil -- success, just stored differently
		end

		-- Roll creature
		local totalWeight = 0
		for _, entry in egg.pool do
			totalWeight += entry.weight
		end

		local roll = math.random() * totalWeight
		local cumulative = 0
		local creatureId = egg.pool[1].creatureId

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
		return true, nil

	elseif reward.type == "boost" then
		-- Activate a timed buff via MonetizationHandler's buff system
		local buffBindable = ServerStorage:FindFirstChild("BF_GetPlayerBuffs")
		-- We can't directly activate buffs via the getter.
		-- Instead, fire a BindableEvent that MonetizationHandler listens to,
		-- or directly use the RE_BuffActivated pattern.
		-- For simplicity, store as a redeemable item.
		local itemKey = `boost_{reward.boostType}_{reward.duration}`
		data.inventory.items[itemKey] = (data.inventory.items[itemKey] or 0) + 1
		return true, nil

	elseif reward.type == "item" then
		local itemKey = reward.itemId or "unknown_item"
		data.inventory.items[itemKey] = (data.inventory.items[itemKey] or 0) + (reward.amount or 1)
		return true, nil
	end

	return false, "UNKNOWN_REWARD_TYPE"
end

--------------------------------------------------------------------------------
-- Claim Reward
--------------------------------------------------------------------------------

RE_ClaimSeasonReward.OnServerEvent:Connect(function(player: Player, tier, track)
	if not BF_ValidateRemoteCall:Invoke(player.UserId, "RE_ClaimSeasonReward", { tier, track }) then return end

	-- Validate
	if typeof(tier) ~= "number" then return end
	if tier ~= math.floor(tier) then return end
	if tier < 1 or tier > MAX_TIER then return end
	if typeof(track) ~= "string" then return end
	if track ~= "free" and track ~= "premium" then return end

	local data = getPlayerData(player)
	ensureCurrentSeason(data)

	-- Must have reached this tier
	if data.seasonPass.tier < tier then
		RE_ClaimResult:FireClient(player, false, tier, track, "TIER_NOT_REACHED")
		return
	end

	-- Premium track requires premium pass
	if track == "premium" and not data.seasonPass.premium then
		RE_ClaimResult:FireClient(player, false, tier, track, "NO_PREMIUM")
		return
	end

	-- Check if already claimed
	local claimedKey = tostring(tier)
	if track == "free" then
		if data.seasonPass.claimedFree[claimedKey] then
			RE_ClaimResult:FireClient(player, false, tier, track, "ALREADY_CLAIMED")
			return
		end
	else
		if data.seasonPass.claimedPremium[claimedKey] then
			RE_ClaimResult:FireClient(player, false, tier, track, "ALREADY_CLAIMED")
			return
		end
	end

	-- Get reward
	local tierData = TIERS[tier]
	if not tierData then
		RE_ClaimResult:FireClient(player, false, tier, track, "INVALID_TIER")
		return
	end

	local reward = if track == "free" then tierData.free else tierData.premium
	if not reward then
		RE_ClaimResult:FireClient(player, false, tier, track, "NO_REWARD")
		return
	end

	-- Deliver
	local success, err = deliverReward(player, data, reward)
	if not success then
		RE_ClaimResult:FireClient(player, false, tier, track, err)
		return
	end

	-- Mark as claimed
	if track == "free" then
		data.seasonPass.claimedFree[claimedKey] = true
	else
		data.seasonPass.claimedPremium[claimedKey] = true
	end

	RE_ClaimResult:FireClient(player, true, tier, track, nil, {
		reward = reward,
		coins = data.coins,
	})
end)

--------------------------------------------------------------------------------
-- Claim All Pending Rewards (convenience)
--------------------------------------------------------------------------------

local RE_ClaimAllSeasonRewards = getOrCreateRemote("RemoteEvent", "RE_ClaimAllSeasonRewards")
local RE_ClaimAllResult = getOrCreateRemote("RemoteEvent", "RE_ClaimAllResult")

RE_ClaimAllSeasonRewards.OnServerEvent:Connect(function(player: Player)
	local data = getPlayerData(player)
	ensureCurrentSeason(data)

	local claimed = {}

	for t = 1, data.seasonPass.tier do
		local tierData = TIERS[t]
		if not tierData then continue end
		local tierKey = tostring(t)

		-- Free track
		if not data.seasonPass.claimedFree[tierKey] then
			local success = deliverReward(player, data, tierData.free)
			if success then
				data.seasonPass.claimedFree[tierKey] = true
				table.insert(claimed, { tier = t, track = "free", reward = tierData.free })
			end
		end

		-- Premium track
		if data.seasonPass.premium and not data.seasonPass.claimedPremium[tierKey] then
			local success = deliverReward(player, data, tierData.premium)
			if success then
				data.seasonPass.claimedPremium[tierKey] = true
				table.insert(claimed, { tier = t, track = "premium", reward = tierData.premium })
			end
		end
	end

	RE_ClaimAllResult:FireClient(player, claimed, data.coins)
end)

--------------------------------------------------------------------------------
-- Get Season Pass Status
--------------------------------------------------------------------------------

RF_GetSeasonPassStatus.OnServerInvoke = function(player: Player)
	local data = getPlayerData(player)
	ensureCurrentSeason(data)

	local sp = data.seasonPass

	-- Build tier status list
	local tierStatuses = {}
	for t = 1, MAX_TIER do
		local tierData = TIERS[t]
		if not tierData then continue end
		local tierKey = tostring(t)

		tierStatuses[t] = {
			tier = t,
			freeReward = tierData.free,
			premiumReward = tierData.premium,
			unlocked = sp.tier >= t,
			freeClaimed = sp.claimedFree[tierKey] == true,
			premiumClaimed = sp.claimedPremium[tierKey] == true,
		}
	end

	-- XP progress for current tier
	local currentTierCumulXP = cumulativeXPForTier(sp.tier)
	local nextTierCumulXP = if sp.tier < MAX_TIER then cumulativeXPForTier(sp.tier + 1) else sp.xp
	local xpIntoCurrentTier = sp.xp - currentTierCumulXP
	local xpNeededForNext = nextTierCumulXP - currentTierCumulXP

	return {
		seasonId = sp.seasonId,
		premium = sp.premium,
		tier = sp.tier,
		maxTier = MAX_TIER,
		xp = sp.xp,
		xpIntoCurrentTier = xpIntoCurrentTier,
		xpNeededForNext = xpNeededForNext,
		tiers = tierStatuses,
	}
end

--------------------------------------------------------------------------------
-- Premium Pass Purchase
--------------------------------------------------------------------------------

if PREMIUM_PASS_ID ~= 0 then
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, wasPurchased: boolean)
		if passId ~= PREMIUM_PASS_ID then return end
		if not wasPurchased then return end

		local data = getPlayerData(player)
		ensureCurrentSeason(data)
		data.seasonPass.premium = true

		RE_SeasonPassPurchased:FireClient(player)
	end)
end

-- Also check on join if they already own the premium pass
local function checkPremiumOwnership(player: Player, data)
	if PREMIUM_PASS_ID == 0 then return end
	if data.seasonPass.premium then return end -- already flagged

	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, PREMIUM_PASS_ID)
	end)

	if success and owns then
		data.seasonPass.premium = true
	end
end

--------------------------------------------------------------------------------
-- XP Award Hooks (listen to game events from other systems)
--------------------------------------------------------------------------------

-- Harvest XP
local RE_HarvestResult = Remotes:FindFirstChild("RE_HarvestResult")
-- We can't listen to RemoteEvents fired to clients from the server side.
-- Instead, other server scripts call BF_AwardSeasonXP. But we also hook
-- into BindableEvents for convenience.

local BE_SeasonXPEvent = getOrCreateBindable("BindableEvent", "BE_SeasonXPEvent") :: BindableEvent

BE_SeasonXPEvent.Event:Connect(function(userId: number, amount: number, source: string)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end
	awardXP(player, amount, source)
end)

