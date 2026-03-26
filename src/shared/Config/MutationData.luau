-- MutationData: Mutation tiers, odds, and multipliers

return {
	golden = {
		name = "Golden",
		rarity = "Uncommon",
		baseChance = 0.10,
		valueMultiplier = 3,
		particleColor = Color3.fromRGB(255, 215, 0),
		particleEffect = "GoldenShimmer",
	},
	rainbow = {
		name = "Rainbow",
		rarity = "Rare",
		baseChance = 0.02,
		valueMultiplier = 8,
		particleColor = Color3.fromRGB(255, 105, 180),
		particleEffect = "RainbowCycle",
	},
	cosmic = {
		name = "Cosmic",
		rarity = "Epic",
		baseChance = 0.002,
		valueMultiplier = 25,
		particleColor = Color3.fromRGB(155, 89, 182),
		particleEffect = "StarfieldAura",
	},
	celestial = {
		name = "Celestial",
		rarity = "Legendary",
		baseChance = 0.0002,
		valueMultiplier = 100,
		particleColor = Color3.fromRGB(255, 69, 0),
		particleEffect = "FullGlowOrbital",
	},
	mythical = {
		name = "Mythical",
		rarity = "Mythical",
		baseChance = 0.00002,
		valueMultiplier = 500,
		particleColor = Color3.fromRGB(0, 255, 255),
		particleEffect = "UniqueModelSound",
	},
	secret = {
		name = "???",
		rarity = "???",
		baseChance = 0.000001,
		valueMultiplier = 10000,
		particleColor = Color3.fromRGB(255, 255, 255),
		particleEffect = "SecretDiscovery",
	},
}
