-- DataManager: Single source of truth for all player data.
-- Provides a centralized in-memory cache that ALL server scripts share.
-- Only GameInit.server.luau should call loadData/saveData directly.
-- Other scripts access data via DataManager.getData(userId).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local DataStore = DataStoreService:GetDataStore("BloomIsland_v1")

local DataManager = {}

-- Default player data template
local DEFAULT_DATA = {
	coins = 50,
	plots = {},
	maxPlots = 6,
	creatures = {},
	inventory = { seeds = {}, items = {} },
	stats = {
		totalHarvests = 0,
		totalCoins = 0,
		rareFinds = 0,
	},
	settings = {
		language = "en",
		musicVolume = 0.5,
	},
	social = {
		gardenRating = 0,
		visitCount = 0,
		giftsGiven = 0,
		giftsReceived = 0,
	},
	upgrades = {
		water = 0,
		fertilizer = 0,
		greenhouse = 0,
		extraSlots = 0,
	},
	gamePasses = {},
	seasonPass = {
		tier = 0,
		premium = false,
		xp = 0,
		seasonId = "",
		claimedFree = {},
		claimedPremium = {},
	},
	dailyQuests = {
		giftsToday = 0,
		lastGiftReset = 0,
		giftQuestClaimed = false,
	},
}

--------------------------------------------------------------------------------
-- Centralized Cache
--------------------------------------------------------------------------------

local cache: { [number]: any } = {}

-- Get cached data for a player. Returns nil if not loaded yet.
function DataManager.getData(userId: number)
	return cache[userId]
end

-- Set data in cache (used by GameInit after loading)
function DataManager.setData(userId: number, data)
	cache[userId] = data
end

-- Remove data from cache (used by GameInit on player leave)
function DataManager.clearData(userId: number)
	cache[userId] = nil
end

-- Get the full cache table (used by auto-save and BindToClose)
function DataManager.getAllCachedData(): { [number]: any }
	return cache
end

--------------------------------------------------------------------------------
-- DataStore Operations
--------------------------------------------------------------------------------

function DataManager.loadData(player: Player)
	local key = `Player_{player.UserId}`
	local success, data = pcall(function()
		return DataStore:GetAsync(key)
	end)

	if success and data then
		-- Deep merge with defaults (handles new fields added in updates)
		for k, v in pairs(DEFAULT_DATA) do
			if data[k] == nil then
				if typeof(v) == "table" then
					data[k] = table.clone(v)
				else
					data[k] = v
				end
			elseif typeof(v) == "table" and typeof(data[k]) == "table" then
				-- Merge one level deeper for sub-tables (stats, social, etc.)
				for subKey, subVal in v do
					if data[k][subKey] == nil then
						data[k][subKey] = subVal
					end
				end
			end
		end
		return data
	else
		-- Deep clone defaults for new players
		local newData = {}
		for k, v in DEFAULT_DATA do
			if typeof(v) == "table" then
				newData[k] = table.clone(v)
			else
				newData[k] = v
			end
		end
		-- Deep clone nested tables
		newData.seasonPass.claimedFree = {}
		newData.seasonPass.claimedPremium = {}
		return newData
	end
end

function DataManager.saveData(player: Player, data)
	local key = `Player_{player.UserId}`
	for attempt = 1, 3 do
		local success, err = pcall(function()
			DataStore:UpdateAsync(key, function()
				return data
			end)
		end)
		if success then return true end
		task.wait(1)
	end
	warn(`Failed to save data for {player.Name}`)
	return false
end

return DataManager
