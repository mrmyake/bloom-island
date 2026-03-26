-- Localization: Shared module for all player-facing strings.
-- Uses key-based lookups with parameter substitution.
-- Falls back to English if LocalizationService has no translation.
--
-- Usage:
--   local L = require(Shared.Localization)
--   label.Text = L("UI.Button.Harvest")
--   label.Text = L("Game.Status.GrowTime", { time = "45s" })

local Localization = {}

--------------------------------------------------------------------------------
-- English Fallback Table
-- Keys follow: Category.Subcategory.Name
--------------------------------------------------------------------------------

local EN: { [string]: string } = {
	-- UI: Top Bar
	["UI.TopBar.Creatures"] = "Creatures",
	["UI.TopBar.Close"] = "Close",

	-- UI: Plot Grid
	["UI.Plot.EmptyPlot"] = "Empty Plot",
	["UI.Plot.TapToPlant"] = "Tap to plant",
	["UI.Plot.Harvest"] = "Harvest",
	["UI.Plot.ReadyToHarvest"] = "Ready to harvest!",

	-- UI: Seed Bar
	["UI.Seeds.Title"] = "Seeds",
	["UI.Seeds.Free"] = "Free",

	-- UI: Creature Panel
	["UI.Creatures.Title"] = "My Creatures",
	["UI.Creatures.NoBonuses"] = "No bonuses active",
	["UI.Creatures.Empty"] = "Hatch eggs to get creatures!",
	["UI.Creatures.Growth"] = "Growth +{pct}%",
	["UI.Creatures.Coins"] = "Coins +{pct}%",
	["UI.Creatures.Mutation"] = "Mutation +{pct}%",

	-- UI: Coin Animation
	["UI.Coins.Gained"] = "+{amount}",

	-- Game: Weather
	["Game.Weather.Sunny"] = "Sunny",
	["Game.Weather.Rainy"] = "Rainy",
	["Game.Weather.Stormy"] = "Stormy",
	["Game.Weather.NorthernLights"] = "Northern Lights",
	["Game.Weather.SolarEclipse"] = "Solar Eclipse",
	["Game.Weather.MeteorShower"] = "Meteor Shower",
	["Game.Weather.ChangedFromTo"] = "Weather changed from {prev} to {next}.",
	["Game.Weather.Current"] = "Current weather: {name}.",

	-- Game: Harvest
	["Game.Harvest.PlantReady"] = "Your {plant} in plot {plot} has finished growing.",
	["Game.Harvest.Earned"] = "Earned {coins} coins!",
	["Game.Harvest.Harvested"] = "Harvested {plant}{mutation}",
	["Game.Harvest.ReadyTitle"] = "Ready to Harvest!",

	-- Game: Mutation
	["Game.Mutation.Title"] = "{rarity} Mutation!",
	["Game.Mutation.Appeared"] = "A {name} mutation appeared on plot {plot}!",
	["Game.Mutation.DiscoveryTitle"] = "{rarity} Discovery!",
	["Game.Mutation.DiscoveryMsg"] = "{player} just discovered a {mutation} {plant}!",

	-- Game: Trade
	["Game.Trade.RequestTitle"] = "Trade Request",
	["Game.Trade.RequestBody"] = "{name} wants to trade with you! ({timeout}s to respond)",
	["Game.Trade.CompleteTitle"] = "Trade Complete",
	["Game.Trade.CompleteBody"] = "The trade was completed successfully!",
	["Game.Trade.CancelledTitle"] = "Trade Cancelled",
	["Game.Trade.FailedTitle"] = "Trade Failed",
	["Game.Trade.Cancel.RequestExpired"] = "Trade request expired.",
	["Game.Trade.Cancel.RequestDeclined"] = "Trade request was declined.",
	["Game.Trade.Cancel.PartnerCancelled"] = "Your trade partner cancelled.",
	["Game.Trade.Cancel.PartnerLeft"] = "Your trade partner left the game.",
	["Game.Trade.Cancel.YouCancelled"] = "You cancelled the trade.",
	["Game.Trade.Cancel.CancelledByTarget"] = "The player declined your trade.",
	["Game.Trade.Cancel.RequesterLeft"] = "The requesting player left.",
	["Game.Trade.Cancel.TargetInTrade"] = "That player is already in a trade.",
	["Game.Trade.Cancel.Default"] = "Trade was cancelled.",
	["Game.Trade.Fail.AlreadyInTrade"] = "You're already in a trade.",
	["Game.Trade.Fail.TargetInTrade"] = "That player is busy trading.",
	["Game.Trade.Fail.PlayerNotFound"] = "Player not found in this server.",
	["Game.Trade.Fail.NotEnoughCoins"] = "Not enough coins to complete trade.",
	["Game.Trade.Fail.NotEnoughSeeds"] = "Missing seeds for this trade.",
	["Game.Trade.Fail.NotEnoughItems"] = "Missing items for this trade.",
	["Game.Trade.Fail.InvalidCreature"] = "Invalid creature in trade offer.",
	["Game.Trade.Fail.ACreaturesFull"] = "You don't have room for more creatures.",
	["Game.Trade.Fail.BCreaturesFull"] = "Your partner doesn't have room for creatures.",
	["Game.Trade.Fail.PlayerLeft"] = "A player left during the trade.",
	["Game.Trade.Fail.Default"] = "Trade failed: {reason}",

	-- Game: Creatures
	["Game.Creature.LevelUpTitle"] = "Level Up!",
	["Game.Creature.LevelUpBody"] = "{name} reached level {level}!",
	["Game.Creature.ReadyToEvolve"] = " Ready to evolve!",
	["Game.Creature.HatchTitle"] = "New Creature!",
	["Game.Creature.HatchBody"] = "You hatched a {rarity} {name}!",
	["Game.Creature.HatchFail.MaxCreatures"] = "Your creature slots are full!",
	["Game.Creature.HatchFail.NotEnoughCoins"] = "Not enough coins for this egg.",
	["Game.Creature.HatchFail.RollFailed"] = "Hatching failed. Try again.",
	["Game.Creature.HatchFail.Default"] = "Could not hatch egg.",
	["Game.Creature.EvolveTitle"] = "Evolution!",
	["Game.Creature.EvolveBody"] = "Your creature evolved into {name}!",
	["Game.Creature.EvolveFail.AlreadyEvolved"] = "This creature has already evolved.",
	["Game.Creature.EvolveFail.LevelTooLow"] = "Creature hasn't reached the required level.",
	["Game.Creature.EvolveFail.NotEnoughCoins"] = "Not enough coins to evolve.",
	["Game.Creature.EvolveFail.Default"] = "Could not evolve creature.",

	-- Game: Gifts
	["Game.Gift.ReceivedTitle"] = "Gift from {name}!",
	["Game.Gift.ReceivedBody"] = "You received {contents}{note}.",
	["Game.Gift.SentTitle"] = "Gift Sent!",
	["Game.Gift.SentBody"] = "Your gift was delivered to {name}.",
	["Game.Gift.FallbackContents"] = "a gift",
	["Game.Gift.OfflineNote"] = " (while you were away)",
	["Game.Gift.SendingTo"] = "Sending to {name}...",
	["Game.Gift.OpenedFrom"] = "Opened gift from {name}!",
	["Game.Gift.SentTo"] = "Gift sent to {name}!",
	["Game.Gift.DailyTitle"] = "Daily Quest Progress",
	["Game.Gift.DailyComplete"] = "Daily Quest Complete!",
	["Game.Gift.DailyBody"] = "Send {goal} gifts: {progress}",
	["Game.Gift.DailyCompleteBody"] = "Send {goal} gifts: {progress} — Claim your reward!",
	["Game.Gift.DailyRewardTitle"] = "Daily Reward!",
	["Game.Gift.DailyRewardBody"] = "You earned {reward} coins for gifting!",

	-- Game: Announcements
	["Game.Announce.Fallback"] = "Announcement",
}

--------------------------------------------------------------------------------
-- Parameter Substitution
-- Replaces {key} placeholders with values from a params table.
--------------------------------------------------------------------------------

local function substitute(template: string, params: { [string]: any }?): string
	if not params then return template end
	local result = template
	for key, value in params do
		result = string.gsub(result, `{{{key}}}`, tostring(value))
	end
	return result
end

--------------------------------------------------------------------------------
-- LocalizationService Integration
-- Attempts to use Roblox's built-in LocalizationService first.
-- Falls back to the EN table if no translation is found.
--------------------------------------------------------------------------------

local localizationTable: LocalizationTable? = nil

local function initLocalizationService()
	local success, result = pcall(function()
		local LocalizationService = game:GetService("LocalizationService")
		-- Try to find a LocalizationTable (imported from CSV)
		for _, child in LocalizationService:GetChildren() do
			if child:IsA("LocalizationTable") then
				return child :: LocalizationTable
			end
		end
		return nil
	end)
	if success then
		localizationTable = result
	end
end

-- Deferred init (safe for both client and server require)
task.defer(initLocalizationService)

--------------------------------------------------------------------------------
-- Main Lookup Function
--------------------------------------------------------------------------------

function Localization.get(key: string, params: { [string]: any }?): string
	-- Try LocalizationService first
	if localizationTable then
		local success, translated = pcall(function()
			return localizationTable:GetEntryValue(key, "en")
		end)
		if success and translated and #translated > 0 then
			return substitute(translated, params)
		end
	end

	-- Fallback to EN table
	local template = EN[key]
	if template then
		return substitute(template, params)
	end

	-- Key not found — return the key itself as a visible debug hint
	warn(`Missing localization key: {key}`)
	return key
end

-- Convenience: get all keys (for tooling / CSV export)
function Localization.getAllKeys(): { string }
	local keys = {}
	for key in EN do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Convenience: get the English table (for CSV generation)
function Localization.getEnglishTable(): { [string]: string }
	return EN
end

--------------------------------------------------------------------------------
-- Make the module callable: L("key", params)
--------------------------------------------------------------------------------

setmetatable(Localization, {
	__call = function(_self, key: string, params: { [string]: any }?)
		return Localization.get(key, params)
	end,
})

return Localization
