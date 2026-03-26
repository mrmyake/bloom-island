-- Types: Shared type definitions for Bloom Island

export type PlotData = {
	seedId: string,
	plantedAt: number,
	mutation: string?,
	growthProgress: number,
}

export type CreatureData = {
	creatureId: string,
	level: number,
	xp: number,
	evolved: boolean,
}

export type PlayerData = {
	coins: number,
	plots: { PlotData },
	maxPlots: number,
	creatures: { CreatureData },
	inventory: {
		seeds: { [string]: number },
		items: { [string]: number },
	},
	stats: {
		totalHarvests: number,
		totalCoins: number,
		rareFinds: number,
	},
	settings: {
		language: string,
		musicVolume: number,
	},
	social: {
		gardenRating: number,
		visitCount: number,
		giftsGiven: number,
		giftsReceived: number,
	},
	upgrades: {
		water: number,
		fertilizer: number,
		greenhouse: number,
		extraSlots: number,
	},
	gamePasses: { [string]: boolean },
	seasonPass: {
		tier: number,
		premium: boolean,
	},
}

return nil
