-- GameInit: Master initialization script that connects all systems on player join.
-- Single source of truth for the player lifecycle:
--   1. Load data from DataStore into centralized cache
--   2. Check game passes (MonetizationHandler)
--   3. Reset/migrate season pass data
--   4. Recalculate creature levels
--   5. Deliver pending offline gifts
--   6. Sync weather to joining player
--   7. Handle garden visit teleport arrivals
--   8. Notify client of initial state
--
-- Also handles: single auto-save loop, single PlayerRemoving, single BindToClose.
-- Eliminates duplicate data loading/saving across all subsystems.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local CreatureData = require(Shared.Config.CreatureData)
local DataManager = require(script.Parent.DataManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local AUTO_SAVE_INTERVAL = 60

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

-- Centralized "player data is ready" signal for subsystems
local RE_PlayerDataReady = getOrCreateRemote("RemoteEvent", "RE_PlayerDataReady")

--------------------------------------------------------------------------------
-- Subsystem References (lazy-loaded from Remotes / ServerStorage)
-- These are optional — if a subsystem hasn't created its remote yet,
-- we skip that step gracefully.
--------------------------------------------------------------------------------

local function findRemote(name: string): Instance?
	return Remotes:FindFirstChild(name)
end

local function findBindable(name: string): Instance?
	return ServerStorage:FindFirstChild(name)
end

--------------------------------------------------------------------------------
-- Game Pass Checking
--------------------------------------------------------------------------------

local GAME_PASSES = GameConfig.GAME_PASSES

local function checkGamePasses(player: Player, data)
	for passName, passId in GAME_PASSES do
		if passId == 0 then continue end
		local success, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if success and owns then
			data.gamePasses[passName] = true
		end
	end
end

--------------------------------------------------------------------------------
-- Season Pass Reset
--------------------------------------------------------------------------------

local function getCurrentSeasonId(): string
	local date = os.date("!*t", os.time())
	return string.format("%04d-%02d", date.year, date.month)
end

local function ensureCurrentSeason(data)
	if not data.seasonPass then
		data.seasonPass = {
			tier = 0, premium = false, xp = 0,
			seasonId = "", claimedFree = {}, claimedPremium = {},
		}
	end

	local currentSeason = getCurrentSeasonId()
	if data.seasonPass.seasonId ~= currentSeason then
		data.seasonPass.tier = 0
		data.seasonPass.xp = 0
		data.seasonPass.seasonId = currentSeason
		data.seasonPass.claimedFree = {}
		data.seasonPass.claimedPremium = {}
		data.seasonPass.premium = false
	end
end

local function checkSeasonPassPremium(player: Player, data)
	local premiumPassId = 0
	pcall(function()
		local SeasonPassData = require(Shared.Config.SeasonPassData)
		premiumPassId = SeasonPassData.PREMIUM_PASS_ID
	end)
	if premiumPassId == 0 or data.seasonPass.premium then return end

	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, premiumPassId)
	end)
	if success and owns then
		data.seasonPass.premium = true
	end
end

--------------------------------------------------------------------------------
-- Creature Level Recalculation
--------------------------------------------------------------------------------

local function recalcCreatureLevels(data)
	if not data.creatures then return end

	local BASE_XP = CreatureData.BASE_XP
	local XP_EXPONENT = CreatureData.XP_EXPONENT
	local MAX_LEVEL = CreatureData.MAX_LEVEL

	local function getLevelFromXP(totalXP: number): number
		for level = MAX_LEVEL, 1, -1 do
			local required = math.floor(BASE_XP * level ^ XP_EXPONENT)
			if totalXP >= required then
				return level
			end
		end
		return 1
	end

	for _, creature in data.creatures do
		creature.level = getLevelFromXP(creature.xp)
		if creature.level > MAX_LEVEL then
			creature.level = MAX_LEVEL
		end
	end
end

--------------------------------------------------------------------------------
-- Daily Quest Reset
--------------------------------------------------------------------------------

local function ensureDailyReset(data)
	if not data.dailyQuests then
		data.dailyQuests = {
			giftsToday = 0,
			lastGiftReset = 0,
			giftQuestClaimed = false,
		}
	end

	local today = math.floor(os.time() / 86400)
	if data.dailyQuests.lastGiftReset ~= today then
		data.dailyQuests.giftsToday = 0
		data.dailyQuests.giftQuestClaimed = false
		data.dailyQuests.lastGiftReset = today
	end
end

--------------------------------------------------------------------------------
-- Pending Gift Delivery
--------------------------------------------------------------------------------

local function deliverPendingGifts(player: Player, data)
	if not data.pendingGiftNotifications then return end
	if #data.pendingGiftNotifications == 0 then return end

	local RE_GiftReceived = findRemote("RE_GiftReceived")
	local RE_GiftAnimation = findRemote("RE_GiftAnimation")

	task.delay(3, function()
		if not player.Parent then return end

		for _, notification in data.pendingGiftNotifications do
			if RE_GiftReceived then
				(RE_GiftReceived :: RemoteEvent):FireClient(player, {
					fromName = notification.fromName,
					summary = notification.summary,
					wasOffline = true,
				})
			end
			if RE_GiftAnimation then
				(RE_GiftAnimation :: RemoteEvent):FireClient(player, "receive", {
					fromName = notification.fromName,
				})
			end
			task.wait(0.5)
		end
	end)

	data.pendingGiftNotifications = {}
end

--------------------------------------------------------------------------------
-- Weather Sync
--------------------------------------------------------------------------------

local function syncWeather(player: Player)
	local RE_WeatherChanged = findRemote("RE_WeatherChanged")
	if not RE_WeatherChanged then return end

	local weatherValue = ReplicatedStorage:FindFirstChild("CurrentWeather")
	local currentWeather = if weatherValue and weatherValue:IsA("StringValue")
		then weatherValue.Value
		else "sunny"

	task.delay(1, function()
		if not player.Parent then return end
		(RE_WeatherChanged :: RemoteEvent):FireClient(player, currentWeather, nil, 0)
	end)
end

--------------------------------------------------------------------------------
-- Garden Visit Arrival (cross-server teleport)
--------------------------------------------------------------------------------

local function handleVisitArrival(player: Player, data)
	local success, teleportData = pcall(function()
		return player:GetJoinData().TeleportData
	end)

	if not success or not teleportData or not teleportData.visitTargetUserId then
		return
	end

	local RE_VisitStarted = findRemote("RE_VisitStarted")
	local RE_VisitFailed = findRemote("RE_VisitFailed")
	if not RE_VisitStarted then return end

	local targetUserId = teleportData.visitTargetUserId

	task.delay(2, function()
		if not player.Parent then return end

		-- Fire the visit initiation remote — GardenVisiting will handle the rest
		local RE_VisitGarden = findRemote("RE_VisitGarden")
		if RE_VisitGarden then
			-- Simulate the visit request from this player
			(RE_VisitGarden :: RemoteEvent):FireServer(targetUserId)
		end
	end)
end

--------------------------------------------------------------------------------
-- Notify Client of Game Passes
--------------------------------------------------------------------------------

local function notifyGamePasses(player: Player, data)
	local RE_GamePassGranted = findRemote("RE_GamePassGranted")
	if not RE_GamePassGranted then return end

	for passName, owned in data.gamePasses do
		if owned then
			(RE_GamePassGranted :: RemoteEvent):FireClient(player, passName)
		end
	end
end

--------------------------------------------------------------------------------
-- Trade Cleanup on Leave
--------------------------------------------------------------------------------

local function cleanupTradesOnLeave(userId: number)
	-- TradingSystem manages its own trade state cleanup via its PlayerRemoving.
	-- We just need to make sure it runs. Since TradingSystem still has its
	-- PlayerRemoving for trade-specific cleanup (cancel active trades, pending
	-- requests), we leave that in place. It no longer saves data though —
	-- GameInit handles that.
end

--------------------------------------------------------------------------------
-- MutationEngine Cleanup on Leave
--------------------------------------------------------------------------------

local function cleanupMutationState(userId: number)
	-- MutationEngine's pity counters and journals are ephemeral.
	-- Its PlayerRemoving handler handles this.
end

--------------------------------------------------------------------------------
-- AntiExploit Cleanup on Leave
--------------------------------------------------------------------------------

local function cleanupAntiExploit(userId: number)
	-- AntiExploit's PlayerRemoving handler handles violations/rateBuckets.
end

--------------------------------------------------------------------------------
-- PLAYER ADDED — Single entry point for all systems
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	-- Step 1: Load data from DataStore into centralized cache
	local data = DataManager.loadData(player)
	DataManager.setData(player.UserId, data)

	-- Step 2: Check game pass ownership
	checkGamePasses(player, data)

	-- Step 3: Season pass migration/reset
	ensureCurrentSeason(data)
	checkSeasonPassPremium(player, data)

	-- Step 4: Recalculate creature levels (in case XP formula changed)
	recalcCreatureLevels(data)

	-- Step 5: Daily quest reset
	ensureDailyReset(data)

	-- Step 6: Deliver pending offline gifts
	deliverPendingGifts(player, data)

	-- Step 7: Sync weather
	syncWeather(player)

	-- Step 8: Handle cross-server visit arrival
	handleVisitArrival(player, data)

	-- Step 9: Notify client of game passes
	notifyGamePasses(player, data)

	-- Step 10: Signal to all systems that this player's data is ready
	RE_PlayerDataReady:FireClient(player)
end)

--------------------------------------------------------------------------------
-- PLAYER REMOVING — Single save point
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId
	local data = DataManager.getData(userId)

	if data then
		DataManager.saveData(player, data)
		DataManager.clearData(userId)
	end
end)

--------------------------------------------------------------------------------
-- AUTO-SAVE — Single loop for all player data
--------------------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)
		for userId, data in DataManager.getAllCachedData() do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				DataManager.saveData(player, data)
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- BIND TO CLOSE — Single shutdown handler
--------------------------------------------------------------------------------

game:BindToClose(function()
	for userId, data in DataManager.getAllCachedData() do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			DataManager.saveData(player, data)
		end
	end
end)
