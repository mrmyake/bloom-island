-- WeatherSystem: Deterministic server-synchronized weather cycles.
-- All servers derive the same weather from UTC time — no cross-server messaging needed.
-- Writes CurrentWeather StringValue for other server scripts to read.
-- Fires RemoteEvents so clients can play visual/audio transitions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local DataManager = require(script.Parent.DataManager)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local CYCLE_DURATION = GameConfig.WEATHER_CYCLE_DURATION -- 300s (5 min)
local WEATHER_WEIGHTS = GameConfig.WEATHER_WEIGHTS
local TICK_INTERVAL = 1 -- check for cycle change every second

-- How many future cycles the WEATHER_RADAR pass can see
local FORECAST_LENGTH = 3

-- Lighting presets per weather type
local LIGHTING_PRESETS = {
	sunny = {
		Ambient = Color3.fromRGB(135, 135, 128),
		OutdoorAmbient = Color3.fromRGB(128, 128, 128),
		Brightness = 2,
		ClockTime = 14,
		FogEnd = 100000,
		FogColor = Color3.fromRGB(192, 216, 240),
	},
	rainy = {
		Ambient = Color3.fromRGB(90, 90, 100),
		OutdoorAmbient = Color3.fromRGB(80, 80, 90),
		Brightness = 1,
		ClockTime = 14,
		FogEnd = 800,
		FogColor = Color3.fromRGB(150, 160, 170),
	},
	stormy = {
		Ambient = Color3.fromRGB(60, 60, 75),
		OutdoorAmbient = Color3.fromRGB(50, 50, 65),
		Brightness = 0.5,
		ClockTime = 15,
		FogEnd = 500,
		FogColor = Color3.fromRGB(100, 105, 115),
	},
	northernLights = {
		Ambient = Color3.fromRGB(40, 50, 80),
		OutdoorAmbient = Color3.fromRGB(30, 40, 70),
		Brightness = 0.8,
		ClockTime = 0,
		FogEnd = 5000,
		FogColor = Color3.fromRGB(20, 30, 60),
	},
	solarEclipse = {
		Ambient = Color3.fromRGB(50, 30, 30),
		OutdoorAmbient = Color3.fromRGB(40, 20, 20),
		Brightness = 0.3,
		ClockTime = 12,
		FogEnd = 2000,
		FogColor = Color3.fromRGB(80, 50, 50),
	},
	meteorShower = {
		Ambient = Color3.fromRGB(50, 50, 70),
		OutdoorAmbient = Color3.fromRGB(40, 40, 60),
		Brightness = 0.6,
		ClockTime = 22,
		FogEnd = 10000,
		FogColor = Color3.fromRGB(30, 30, 50),
	},
}

--------------------------------------------------------------------------------
-- Remotes
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

local RE_WeatherChanged = getOrCreateRemote("RemoteEvent", "RE_WeatherChanged")
local RF_GetWeather = getOrCreateRemote("RemoteFunction", "RF_GetWeather")
local RF_GetForecast = getOrCreateRemote("RemoteFunction", "RF_GetForecast")

--------------------------------------------------------------------------------
-- CurrentWeather StringValue (read by PlantSystem, MutationEngine)
--------------------------------------------------------------------------------

local currentWeatherValue: StringValue
do
	local existing = ReplicatedStorage:FindFirstChild("CurrentWeather")
	if existing and existing:IsA("StringValue") then
		currentWeatherValue = existing :: StringValue
	else
		currentWeatherValue = Instance.new("StringValue")
		currentWeatherValue.Name = "CurrentWeather"
		currentWeatherValue.Value = "sunny"
		currentWeatherValue.Parent = ReplicatedStorage
	end
end

--------------------------------------------------------------------------------
-- Deterministic Weather from Time
--------------------------------------------------------------------------------

-- Build a sorted list of weather types with cumulative weights for consistent
-- iteration order (Luau table iteration order is not guaranteed for dicts).
local weatherEntries: { { id: string, weight: number } } = {}
local totalWeight = 0
for id, weight in WEATHER_WEIGHTS do
	table.insert(weatherEntries, { id = id, weight = weight })
	totalWeight += weight
end
table.sort(weatherEntries, function(a, b)
	return a.id < b.id
end)

--[[
	Derives the weather for a given cycle index using a simple deterministic hash.
	Every server in the game will compute the same result for the same cycleIndex
	because the seed is purely time-based with no server-local state.
]]
local function weatherForCycle(cycleIndex: number): string
	-- Simple hash: multiply by a large prime, mod by total weight
	-- This gives a deterministic "random" number per cycle
	local hash = (cycleIndex * 2654435761) % 2^32
	local pick = hash % totalWeight

	local cumulative = 0
	for _, entry in weatherEntries do
		cumulative += entry.weight
		if pick < cumulative then
			return entry.id
		end
	end

	-- Fallback (should never reach here)
	return "sunny"
end

local function getCurrentCycleIndex(): number
	return math.floor(os.time() / CYCLE_DURATION)
end

local function getSecondsUntilNextCycle(): number
	local now = os.time()
	local cycleStart = getCurrentCycleIndex() * CYCLE_DURATION
	local cycleEnd = cycleStart + CYCLE_DURATION
	return cycleEnd - now
end

--------------------------------------------------------------------------------
-- Forecast (for WEATHER_RADAR game pass)
--------------------------------------------------------------------------------

local function getForecast(count: number): { { weather: string, startsIn: number } }
	local currentCycle = getCurrentCycleIndex()
	local now = os.time()
	local result = {}

	for i = 1, count do
		local futureCycle = currentCycle + i
		local futureStart = futureCycle * CYCLE_DURATION
		table.insert(result, {
			weather = weatherForCycle(futureCycle),
			startsIn = futureStart - now,
		})
	end

	return result
end

--------------------------------------------------------------------------------
-- Apply Lighting
--------------------------------------------------------------------------------

local function applyLighting(weatherId: string)
	local preset = LIGHTING_PRESETS[weatherId]
	if not preset then return end

	for property, value in preset do
		(Lighting :: any)[property] = value
	end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local activeWeather: string = "sunny"
local activeCycleIndex: number = -1

local function transitionToWeather(weatherId: string, cycleIndex: number)
	if weatherId == activeWeather and cycleIndex == activeCycleIndex then
		return
	end

	local previousWeather = activeWeather
	activeWeather = weatherId
	activeCycleIndex = cycleIndex

	-- Update the shared StringValue
	currentWeatherValue.Value = weatherId

	-- Update server-side lighting
	applyLighting(weatherId)

	-- Notify all connected clients
	local timeRemaining = getSecondsUntilNextCycle()
	RE_WeatherChanged:FireAllClients(weatherId, previousWeather, timeRemaining)
end

--------------------------------------------------------------------------------
-- RemoteFunction handlers
--------------------------------------------------------------------------------

RF_GetWeather.OnServerInvoke = function(_player: Player)
	return activeWeather, getSecondsUntilNextCycle()
end

RF_GetForecast.OnServerInvoke = function(player: Player)
	-- Only players with WEATHER_RADAR pass get the forecast
	local data = DataManager.getData(player.UserId)
	if not data or not data.gamePasses.WEATHER_RADAR then
		return nil
	end
	return getForecast(FORECAST_LENGTH)
end

-- Weather sync for newly joined players handled by GameInit.server.luau

--------------------------------------------------------------------------------
-- Main Loop
--------------------------------------------------------------------------------

-- Initialize immediately
local initialCycle = getCurrentCycleIndex()
local initialWeather = weatherForCycle(initialCycle)
transitionToWeather(initialWeather, initialCycle)

task.spawn(function()
	while true do
		task.wait(TICK_INTERVAL)

		local cycleIndex = getCurrentCycleIndex()
		if cycleIndex ~= activeCycleIndex then
			local newWeather = weatherForCycle(cycleIndex)
			transitionToWeather(newWeather, cycleIndex)
		end
	end
end)
