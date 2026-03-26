-- GameConfig: Global game settings

return {
	-- Economy
	STARTING_COINS = 50,
	MAX_PLOTS_BASE = 6,
	PLOTS_PER_UPGRADE = 2,
	
	-- Weather cycle (seconds)
	WEATHER_CYCLE_DURATION = 300, -- 5 minutes
	
	-- Weather types and their weights
	WEATHER_WEIGHTS = {
		sunny = 40,
		rainy = 25,
		stormy = 15,
		northernLights = 10,
		solarEclipse = 7,
		meteorShower = 3,
	},
	
	-- Growth multipliers per weather
	WEATHER_GROWTH_MULT = {
		sunny = 1,
		rainy = 2,
		stormy = 1,
		northernLights = 2,
		solarEclipse = 1.5,
		meteorShower = 1,
	},
	
	-- Mutation multipliers per weather
	WEATHER_MUTATION_MULT = {
		sunny = 1,
		rainy = 1,
		stormy = 3,
		northernLights = 2,
		solarEclipse = 5,
		meteorShower = 2,
	},
	
	-- Upgrade costs (base * costMult^level)
	UPGRADES = {
		water = { baseCost = 200, costMult = 2.2, growSpeedBonus = 0.20 },
		fertilizer = { baseCost = 500, costMult = 2.5, valueBonus = 0.25 },
		greenhouse = { baseCost = 1000, costMult = 3.0, mutationBonus = 0.30 },
		extraSlots = { baseCost = 300, costMult = 2.8, slotsPerLevel = 2 },
	},
	
	-- Game Pass IDs (replace with actual Roblox IDs after creating them)
	GAME_PASSES = {
		VIP = 0,
		AUTO_HARVEST = 0,
		EXTRA_PLOTS = 0,
		MEGA_PLOTS = 0,
		TRADING_PRO = 0,
		WEATHER_RADAR = 0,
	},
	
	-- Developer Product IDs (replace with actual IDs)
	DEV_PRODUCTS = {
		LUCKY_CHARM = 0,
		GROWTH_BOOST = 0,
		PREMIUM_EGG = 0,
		LEGENDARY_EGG = 0,
		SEED_PACK = 0,
		GARDEN_RESET = 0,
	},
}
