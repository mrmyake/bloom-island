-- SeasonPassData: Season pass tier definitions, XP curve, and reward tracks.
-- Free track has a reward every tier. Premium track has upgraded rewards.

local SeasonPassData = {}

--------------------------------------------------------------------------------
-- Season Settings
--------------------------------------------------------------------------------

-- Season ID format: "YYYY-MM" (resets monthly)
-- The server computes the current seasonId from os.time()

SeasonPassData.MAX_TIER = 30

-- XP required per tier (cumulative): BASE_XP_PER_TIER * tier ^ XP_SCALE
SeasonPassData.BASE_XP_PER_TIER = 100
SeasonPassData.XP_SCALE = 1.15

-- XP Sources (awarded by SeasonalPass.server.luau)
SeasonPassData.XP_SOURCES = {
	harvest = 10,              -- per plant harvested
	harvestMutation = 50,      -- bonus for harvesting a mutated plant
	tradeComplete = 30,        -- per completed trade
	giftSent = 15,             -- per gift sent
	gardenVisit = 5,           -- per garden visited
	creatureEvolve = 100,      -- per creature evolution
}

-- Premium pass Game Pass ID (replace with actual Roblox ID)
SeasonPassData.PREMIUM_PASS_ID = 0

--------------------------------------------------------------------------------
-- Reward Definitions
-- type: "coins", "seeds", "creature_egg", "item", "title", "emote", "boost"
--------------------------------------------------------------------------------

SeasonPassData.Tiers = {
	-- Tier 1
	{
		free = { type = "coins", amount = 100 },
		premium = { type = "coins", amount = 250 },
	},
	-- Tier 2
	{
		free = { type = "seeds", seedId = "tulip", amount = 5 },
		premium = { type = "seeds", seedId = "rose", amount = 5 },
	},
	-- Tier 3
	{
		free = { type = "coins", amount = 150 },
		premium = { type = "creature_egg", eggId = "basic" },
	},
	-- Tier 4
	{
		free = { type = "seeds", seedId = "rose", amount = 3 },
		premium = { type = "seeds", seedId = "sunflower", amount = 5 },
	},
	-- Tier 5
	{
		free = { type = "coins", amount = 200 },
		premium = { type = "boost", boostType = "growthBoost", duration = 300 },
	},
	-- Tier 6
	{
		free = { type = "seeds", seedId = "daisy", amount = 10 },
		premium = { type = "coins", amount = 500 },
	},
	-- Tier 7
	{
		free = { type = "coins", amount = 250 },
		premium = { type = "seeds", seedId = "bonsai", amount = 3 },
	},
	-- Tier 8
	{
		free = { type = "seeds", seedId = "sunflower", amount = 3 },
		premium = { type = "creature_egg", eggId = "premium" },
	},
	-- Tier 9
	{
		free = { type = "coins", amount = 300 },
		premium = { type = "boost", boostType = "luckyCharm", duration = 300 },
	},
	-- Tier 10
	{
		free = { type = "creature_egg", eggId = "basic" },
		premium = { type = "coins", amount = 1000 },
	},
	-- Tier 11
	{
		free = { type = "coins", amount = 350 },
		premium = { type = "seeds", seedId = "orchid", amount = 2 },
	},
	-- Tier 12
	{
		free = { type = "seeds", seedId = "bonsai", amount = 2 },
		premium = { type = "creature_egg", eggId = "premium" },
	},
	-- Tier 13
	{
		free = { type = "coins", amount = 400 },
		premium = { type = "coins", amount = 1000 },
	},
	-- Tier 14
	{
		free = { type = "seeds", seedId = "tulip", amount = 10 },
		premium = { type = "boost", boostType = "growthBoost", duration = 600 },
	},
	-- Tier 15
	{
		free = { type = "coins", amount = 500 },
		premium = { type = "creature_egg", eggId = "legendary" },
	},
	-- Tier 16
	{
		free = { type = "seeds", seedId = "rose", amount = 5 },
		premium = { type = "coins", amount = 1500 },
	},
	-- Tier 17
	{
		free = { type = "coins", amount = 500 },
		premium = { type = "seeds", seedId = "orchid", amount = 3 },
	},
	-- Tier 18
	{
		free = { type = "creature_egg", eggId = "basic" },
		premium = { type = "boost", boostType = "luckyCharm", duration = 600 },
	},
	-- Tier 19
	{
		free = { type = "coins", amount = 600 },
		premium = { type = "creature_egg", eggId = "premium" },
	},
	-- Tier 20
	{
		free = { type = "seeds", seedId = "sunflower", amount = 5 },
		premium = { type = "coins", amount = 2000 },
	},
	-- Tier 21
	{
		free = { type = "coins", amount = 700 },
		premium = { type = "seeds", seedId = "bonsai", amount = 5 },
	},
	-- Tier 22
	{
		free = { type = "seeds", seedId = "bonsai", amount = 3 },
		premium = { type = "creature_egg", eggId = "premium" },
	},
	-- Tier 23
	{
		free = { type = "coins", amount = 800 },
		premium = { type = "boost", boostType = "growthBoost", duration = 900 },
	},
	-- Tier 24
	{
		free = { type = "creature_egg", eggId = "basic" },
		premium = { type = "coins", amount = 2500 },
	},
	-- Tier 25
	{
		free = { type = "coins", amount = 1000 },
		premium = { type = "creature_egg", eggId = "legendary" },
	},
	-- Tier 26
	{
		free = { type = "seeds", seedId = "orchid", amount = 2 },
		premium = { type = "coins", amount = 3000 },
	},
	-- Tier 27
	{
		free = { type = "coins", amount = 1000 },
		premium = { type = "boost", boostType = "luckyCharm", duration = 900 },
	},
	-- Tier 28
	{
		free = { type = "seeds", seedId = "sunflower", amount = 8 },
		premium = { type = "creature_egg", eggId = "legendary" },
	},
	-- Tier 29
	{
		free = { type = "coins", amount = 1500 },
		premium = { type = "coins", amount = 5000 },
	},
	-- Tier 30
	{
		free = { type = "creature_egg", eggId = "premium" },
		premium = { type = "creature_egg", eggId = "legendary" },
	},
}

return SeasonPassData
