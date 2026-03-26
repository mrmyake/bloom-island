-- CreatureData: Creature definitions, egg pools, evolution, and passive bonuses
-- Shared between server and client

local CreatureData = {}

--------------------------------------------------------------------------------
-- Passive Bonus Types
--   growthSpeed  — multiplier on plant grow speed (stacks additively)
--   coinValue    — multiplier on harvest coin value
--   mutationLuck — multiplier on mutation chance
--   xpGain       — multiplier on creature XP from feeding
--------------------------------------------------------------------------------

CreatureData.Creatures = {
	-- Common
	sproutling = {
		name = "Sproutling",
		rarity = "Common",
		bonusType = "growthSpeed",
		bonusAmount = 0.05,
		evolvedBonusMult = 2.5,
		evolveLevel = 10,
		evolvedName = "Bloomkin",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},
	petalfly = {
		name = "Petalfly",
		rarity = "Common",
		bonusType = "coinValue",
		bonusAmount = 0.05,
		evolvedBonusMult = 2.5,
		evolveLevel = 10,
		evolvedName = "Florawing",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},
	mudhopper = {
		name = "Mudhopper",
		rarity = "Common",
		bonusType = "xpGain",
		bonusAmount = 0.08,
		evolvedBonusMult = 2.5,
		evolveLevel = 10,
		evolvedName = "Bogstrider",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},

	-- Uncommon
	sunmote = {
		name = "Sunmote",
		rarity = "Uncommon",
		bonusType = "growthSpeed",
		bonusAmount = 0.10,
		evolvedBonusMult = 2.5,
		evolveLevel = 15,
		evolvedName = "Solarch",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},
	dewdrop = {
		name = "Dewdrop",
		rarity = "Uncommon",
		bonusType = "coinValue",
		bonusAmount = 0.10,
		evolvedBonusMult = 2.5,
		evolveLevel = 15,
		evolvedName = "Mistweaver",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},

	-- Rare
	thornback = {
		name = "Thornback",
		rarity = "Rare",
		bonusType = "mutationLuck",
		bonusAmount = 0.10,
		evolvedBonusMult = 3,
		evolveLevel = 20,
		evolvedName = "Briarwarden",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},
	glowbug = {
		name = "Glowbug",
		rarity = "Rare",
		bonusType = "growthSpeed",
		bonusAmount = 0.15,
		evolvedBonusMult = 3,
		evolveLevel = 20,
		evolvedName = "Radiantbeetle",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},

	-- Epic
	stormwisp = {
		name = "Stormwisp",
		rarity = "Epic",
		bonusType = "mutationLuck",
		bonusAmount = 0.20,
		evolvedBonusMult = 3,
		evolveLevel = 25,
		evolvedName = "Tempestsprite",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},

	-- Legendary
	celestine = {
		name = "Celestine",
		rarity = "Legendary",
		bonusType = "coinValue",
		bonusAmount = 0.30,
		evolvedBonusMult = 3,
		evolveLevel = 30,
		evolvedName = "Astralion",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},
	mythbloom = {
		name = "Mythbloom",
		rarity = "Legendary",
		bonusType = "mutationLuck",
		bonusAmount = 0.30,
		evolvedBonusMult = 3,
		evolveLevel = 30,
		evolvedName = "Eternaflora",
		icon = "rbxassetid://0",
		evolvedIcon = "rbxassetid://0",
	},
}

--------------------------------------------------------------------------------
-- Egg Definitions
-- Each egg has a coin cost and a weighted pool of creature IDs.
--------------------------------------------------------------------------------

CreatureData.Eggs = {
	basic = {
		name = "Basic Egg",
		cost = 500,
		icon = "rbxassetid://0",
		pool = {
			{ creatureId = "sproutling", weight = 40 },
			{ creatureId = "petalfly",   weight = 35 },
			{ creatureId = "mudhopper",  weight = 25 },
		},
	},
	premium = {
		name = "Premium Egg",
		cost = 2500,
		icon = "rbxassetid://0",
		pool = {
			{ creatureId = "sproutling", weight = 15 },
			{ creatureId = "petalfly",   weight = 15 },
			{ creatureId = "mudhopper",  weight = 10 },
			{ creatureId = "sunmote",    weight = 25 },
			{ creatureId = "dewdrop",    weight = 20 },
			{ creatureId = "thornback",  weight = 10 },
			{ creatureId = "glowbug",    weight = 5 },
		},
	},
	legendary = {
		name = "Legendary Egg",
		cost = 15000,
		icon = "rbxassetid://0",
		pool = {
			{ creatureId = "sunmote",    weight = 15 },
			{ creatureId = "dewdrop",    weight = 15 },
			{ creatureId = "thornback",  weight = 20 },
			{ creatureId = "glowbug",    weight = 20 },
			{ creatureId = "stormwisp",  weight = 18 },
			{ creatureId = "celestine",  weight = 7 },
			{ creatureId = "mythbloom",  weight = 5 },
		},
	},
}

--------------------------------------------------------------------------------
-- Leveling
--------------------------------------------------------------------------------

-- XP required to reach a given level: BASE_XP * level ^ XP_EXPONENT
CreatureData.BASE_XP = 50
CreatureData.XP_EXPONENT = 1.8

-- Maximum creature level (evolution doesn't raise the cap, it unlocks bonus)
CreatureData.MAX_LEVEL = 30

-- Maximum number of creatures a player can own
CreatureData.MAX_CREATURES = 6

-- XP granted per plant baseValue point when feeding
CreatureData.XP_PER_VALUE = 0.5

-- Coin cost to evolve (on top of reaching the level)
CreatureData.EVOLVE_COIN_COST_MULT = 10 -- evolve cost = creature evolveLevel * this

--------------------------------------------------------------------------------
-- Plant Tier XP Bonuses (bonus multiplier when feeding plants of these tiers)
--------------------------------------------------------------------------------

CreatureData.FEED_TIER_MULT = {
	Common = 1,
	Uncommon = 1.5,
	Rare = 2.5,
}

return CreatureData
