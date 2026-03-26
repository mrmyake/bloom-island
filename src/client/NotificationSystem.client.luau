-- NotificationSystem: Toast notifications that slide in from the right,
-- stack vertically, and auto-dismiss after a configurable duration.
-- Listens to server RemoteEvents for plant, mutation, weather, trade,
-- and announcement triggers.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local MutationData = require(Shared.Config.MutationData)
local L = require(Shared.Localization)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local TOAST_WIDTH = 320
local TOAST_HEIGHT = 72
local TOAST_PADDING = 8
local TOAST_MARGIN_RIGHT = 16
local TOAST_MARGIN_TOP = 64 -- below top bar
local MAX_VISIBLE = 5
local DEFAULT_DURATION = 4 -- seconds
local SLIDE_IN_TIME = 0.35
local SLIDE_OUT_TIME = 0.3
local RESTACK_TIME = 0.25

--------------------------------------------------------------------------------
-- Notification Types — color, icon, default duration
--------------------------------------------------------------------------------

type NotifConfig = {
	color: Color3,
	icon: string,
	duration: number,
}

local NOTIF_TYPES: { [string]: NotifConfig } = {
	harvest = {
		color = Color3.fromRGB(76, 175, 80),
		icon = "🌾",
		duration = 4,
	},
	mutation = {
		color = Color3.fromRGB(255, 193, 7),
		icon = "✨",
		duration = 5,
	},
	weather = {
		color = Color3.fromRGB(33, 150, 243),
		icon = "🌤️",
		duration = 4,
	},
	trade = {
		color = Color3.fromRGB(156, 39, 176),
		icon = "🤝",
		duration = 6,
	},
	gift = {
		color = Color3.fromRGB(233, 30, 99),
		icon = "🎁",
		duration = 5,
	},
	announcement = {
		color = Color3.fromRGB(255, 87, 34),
		icon = "📢",
		duration = 6,
	},
	info = {
		color = Color3.fromRGB(96, 125, 139),
		icon = "ℹ️",
		duration = 3,
	},
	error = {
		color = Color3.fromRGB(244, 67, 54),
		icon = "⚠️",
		duration = 4,
	},
	creature = {
		color = Color3.fromRGB(0, 150, 136),
		icon = "🐾",
		duration = 4,
	},
	levelup = {
		color = Color3.fromRGB(103, 58, 183),
		icon = "⬆️",
		duration = 4,
	},
}

local WEATHER_NAME_KEYS: { [string]: string } = {
	sunny = "Game.Weather.Sunny",
	rainy = "Game.Weather.Rainy",
	stormy = "Game.Weather.Stormy",
	northernLights = "Game.Weather.NorthernLights",
	solarEclipse = "Game.Weather.SolarEclipse",
	meteorShower = "Game.Weather.MeteorShower",
}

local WEATHER_ICONS: { [string]: string } = {
	sunny = "☀️",
	rainy = "🌧️",
	stormy = "⛈️",
	northernLights = "🌌",
	solarEclipse = "🌑",
	meteorShower = "☄️",
}

--------------------------------------------------------------------------------
-- ScreenGui
--------------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "NotificationGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 10
screenGui.Parent = playerGui

-- Container anchored to top-right
local container = Instance.new("Frame")
container.Name = "ToastContainer"
container.Size = UDim2.new(0, TOAST_WIDTH + TOAST_MARGIN_RIGHT, 1, 0)
container.AnchorPoint = Vector2.new(1, 0)
container.Position = UDim2.new(1, 0, 0, 0)
container.BackgroundTransparency = 1
container.Parent = screenGui

--------------------------------------------------------------------------------
-- Toast Queue & Stack
--------------------------------------------------------------------------------

type ToastData = {
	frame: Frame,
	index: number,
	dismissAt: number,
	dismissing: boolean,
}

local activeToasts: { ToastData } = {}
local queue: { { notifType: string, title: string, body: string, duration: number? } } = {}

local function getTargetY(stackIndex: number): number
	return TOAST_MARGIN_TOP + (stackIndex - 1) * (TOAST_HEIGHT + TOAST_PADDING)
end

local function restackToasts()
	for i, toast in activeToasts do
		toast.index = i
		local targetY = getTargetY(i)
		TweenService:Create(
			toast.frame,
			TweenInfo.new(RESTACK_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0, 0, 0, targetY) }
		):Play()
	end
end

local function dismissToast(toast: ToastData)
	if toast.dismissing then return end
	toast.dismissing = true

	-- Slide out to the right
	local tween = TweenService:Create(
		toast.frame,
		TweenInfo.new(SLIDE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = UDim2.new(0, TOAST_WIDTH + TOAST_MARGIN_RIGHT + 10, 0, toast.frame.Position.Y.Offset) }
	)
	tween:Play()
	tween.Completed:Connect(function()
		toast.frame:Destroy()
	end)

	-- Remove from active list and restack
	local idx = table.find(activeToasts, toast)
	if idx then
		table.remove(activeToasts, idx)
	end
	restackToasts()
end

--------------------------------------------------------------------------------
-- Toast Builder
--------------------------------------------------------------------------------

local function createToast(notifType: string, title: string, body: string, duration: number?)
	local config = NOTIF_TYPES[notifType] or NOTIF_TYPES.info
	local dismissDuration = duration or config.duration or DEFAULT_DURATION

	-- Evict oldest if at max
	while #activeToasts >= MAX_VISIBLE do
		dismissToast(activeToasts[1])
	end

	local stackIndex = #activeToasts + 1
	local targetY = getTargetY(stackIndex)

	-- Toast frame — starts off-screen to the right
	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.Size = UDim2.new(0, TOAST_WIDTH, 0, TOAST_HEIGHT)
	frame.Position = UDim2.new(0, TOAST_WIDTH + TOAST_MARGIN_RIGHT + 10, 0, targetY)
	frame.BackgroundColor3 = Color3.fromRGB(38, 38, 38)
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	-- Accent bar on the left edge
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(0, 4, 1, -8)
	accent.Position = UDim2.new(0, 4, 0, 4)
	accent.BackgroundColor3 = config.color
	accent.BorderSizePixel = 0
	accent.Parent = frame

	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(0, 2)
	accentCorner.Parent = accent

	-- Icon
	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.new(0, 32, 0, 32)
	iconLabel.Position = UDim2.new(0, 14, 0, 10)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = config.icon
	iconLabel.TextSize = 22
	iconLabel.Font = Enum.Font.Gotham
	iconLabel.Parent = frame

	-- Title
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -80, 0, 20)
	titleLabel.Position = UDim2.new(0, 50, 0, 8)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextSize = 14
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextColor3 = Color3.new(1, 1, 1)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Parent = frame

	-- Body
	local bodyLabel = Instance.new("TextLabel")
	bodyLabel.Name = "Body"
	bodyLabel.Size = UDim2.new(1, -80, 0, 32)
	bodyLabel.Position = UDim2.new(0, 50, 0, 28)
	bodyLabel.BackgroundTransparency = 1
	bodyLabel.Text = body
	bodyLabel.TextSize = 12
	bodyLabel.Font = Enum.Font.Gotham
	bodyLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	bodyLabel.TextXAlignment = Enum.TextXAlignment.Left
	bodyLabel.TextWrapped = true
	bodyLabel.TextTruncate = Enum.TextTruncate.AtEnd
	bodyLabel.Parent = frame

	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Size = UDim2.new(0, 24, 0, 24)
	closeBtn.Position = UDim2.new(1, -28, 0, 4)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Text = "✕"
	closeBtn.TextSize = 14
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextColor3 = Color3.fromRGB(150, 150, 150)
	closeBtn.Parent = frame

	-- Progress bar (auto-dismiss timer)
	local progressBg = Instance.new("Frame")
	progressBg.Name = "ProgressBg"
	progressBg.Size = UDim2.new(1, -16, 0, 3)
	progressBg.Position = UDim2.new(0, 8, 1, -7)
	progressBg.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	progressBg.BorderSizePixel = 0
	progressBg.Parent = frame

	local progressCorner = Instance.new("UICorner")
	progressCorner.CornerRadius = UDim.new(0, 2)
	progressCorner.Parent = progressBg

	local progressFill = Instance.new("Frame")
	progressFill.Name = "Fill"
	progressFill.Size = UDim2.new(1, 0, 1, 0)
	progressFill.BackgroundColor3 = config.color
	progressFill.BorderSizePixel = 0
	progressFill.Parent = progressBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 2)
	fillCorner.Parent = progressFill

	-- Build toast data
	local toast: ToastData = {
		frame = frame,
		index = stackIndex,
		dismissAt = os.clock() + dismissDuration,
		dismissing = false,
	}
	table.insert(activeToasts, toast)

	-- Slide in
	TweenService:Create(
		frame,
		TweenInfo.new(SLIDE_IN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0, 0, 0, targetY) }
	):Play()

	-- Progress bar shrink
	TweenService:Create(
		progressFill,
		TweenInfo.new(dismissDuration, Enum.EasingStyle.Linear),
		{ Size = UDim2.new(0, 0, 1, 0) }
	):Play()

	-- Auto-dismiss
	task.delay(dismissDuration, function()
		dismissToast(toast)
	end)

	-- Manual close
	closeBtn.Activated:Connect(function()
		dismissToast(toast)
	end)

	return toast
end

--------------------------------------------------------------------------------
-- Public API (for other client scripts to call via BindableEvent if needed)
--------------------------------------------------------------------------------

local function notify(notifType: string, title: string, body: string, duration: number?)
	createToast(notifType, title, body, duration)
end

-- BindableEvent so other client scripts can trigger notifications
local notifyBindable = Instance.new("BindableEvent")
notifyBindable.Name = "NotifyEvent"
notifyBindable.Parent = ReplicatedStorage.Remotes

notifyBindable.Event:Connect(function(notifType: string, title: string, body: string, duration: number?)
	notify(notifType, title, body, duration)
end)

--------------------------------------------------------------------------------
-- Remote Event Listeners
--------------------------------------------------------------------------------

-- Wait for remotes with pcall so the script doesn't break if one is missing
local function waitRemote(name: string): RemoteEvent?
	local success, remote = pcall(function()
		return Remotes:WaitForChild(name, 5)
	end)
	if success and remote then
		return remote :: RemoteEvent
	end
	return nil
end

-- Plant ready to harvest
local RE_PlantGrown = waitRemote("RE_PlantGrown")
if RE_PlantGrown then
	RE_PlantGrown.OnClientEvent:Connect(function(plotIndex: number, seedId: string)
		local plant = PlantData[seedId]
		local name = if plant then plant.name else seedId
		notify("harvest", L("Game.Harvest.ReadyTitle"), L("Game.Harvest.PlantReady", { plant = name, plot = plotIndex }))
	end)
end

-- Mutation discovered
local RE_MutationRolled = waitRemote("RE_MutationRolled")
if RE_MutationRolled then
	RE_MutationRolled.OnClientEvent:Connect(function(plotIndex: number, mutationId: string)
		local mutData = MutationData[mutationId]
		local name = if mutData then mutData.name else mutationId
		local rarity = if mutData then mutData.rarity else "Unknown"
		notify("mutation", L("Game.Mutation.Title", { rarity = rarity }), L("Game.Mutation.Appeared", { name = name, plot = plotIndex }))
	end)
end

-- Weather change
local RE_WeatherChanged = waitRemote("RE_WeatherChanged")
if RE_WeatherChanged then
	RE_WeatherChanged.OnClientEvent:Connect(function(newWeather: string, previousWeather: string?, _timeRemaining: number?)
		local nameKey = WEATHER_NAME_KEYS[newWeather]
		local name = if nameKey then L(nameKey) else newWeather
		local icon = WEATHER_ICONS[newWeather] or "🌤️"
		local body: string
		if previousWeather then
			local prevKey = WEATHER_NAME_KEYS[previousWeather]
			local prevName = if prevKey then L(prevKey) else previousWeather
			body = L("Game.Weather.ChangedFromTo", { prev = prevName, next = name })
		else
			body = L("Game.Weather.Current", { name = name })
		end

		-- Override icon for weather notifications
		local config = NOTIF_TYPES.weather
		local saved = config.icon
		config.icon = icon
		notify("weather", `{icon} {name}`, body)
		config.icon = saved
	end)
end

-- Trade request received
local RE_TradeRequested = waitRemote("RE_TradeRequested")
if RE_TradeRequested then
	RE_TradeRequested.OnClientEvent:Connect(function(_fromUserId: number, fromName: string, timeout: number?)
		notify("trade", L("Game.Trade.RequestTitle"), L("Game.Trade.RequestBody", { name = fromName, timeout = timeout or 30 }), 8)
	end)
end

-- Trade completed
local RE_TradeCompleted = waitRemote("RE_TradeCompleted")
if RE_TradeCompleted then
	RE_TradeCompleted.OnClientEvent:Connect(function(_tradeId: string, _result)
		notify("trade", L("Game.Trade.CompleteTitle"), L("Game.Trade.CompleteBody"))
	end)
end

-- Trade cancelled
local RE_TradeCancelled = waitRemote("RE_TradeCancelled")
if RE_TradeCancelled then
	RE_TradeCancelled.OnClientEvent:Connect(function(reason: string)
		local cancelKeys: { [string]: string } = {
			REQUEST_EXPIRED = "Game.Trade.Cancel.RequestExpired",
			REQUEST_DECLINED = "Game.Trade.Cancel.RequestDeclined",
			PARTNER_CANCELLED = "Game.Trade.Cancel.PartnerCancelled",
			PARTNER_LEFT = "Game.Trade.Cancel.PartnerLeft",
			YOU_CANCELLED = "Game.Trade.Cancel.YouCancelled",
			CANCELLED_BY_TARGET = "Game.Trade.Cancel.CancelledByTarget",
			REQUESTER_LEFT = "Game.Trade.Cancel.RequesterLeft",
			TARGET_IN_TRADE = "Game.Trade.Cancel.TargetInTrade",
		}
		local key = cancelKeys[reason] or "Game.Trade.Cancel.Default"
		notify("info", L("Game.Trade.CancelledTitle"), L(key))
	end)
end

-- Trade failed
local RE_TradeFailed = waitRemote("RE_TradeFailed")
if RE_TradeFailed then
	RE_TradeFailed.OnClientEvent:Connect(function(reason: string)
		local failKeys: { [string]: string } = {
			ALREADY_IN_TRADE = "Game.Trade.Fail.AlreadyInTrade",
			TARGET_IN_TRADE = "Game.Trade.Fail.TargetInTrade",
			PLAYER_NOT_FOUND = "Game.Trade.Fail.PlayerNotFound",
			NOT_ENOUGH_COINS = "Game.Trade.Fail.NotEnoughCoins",
			NOT_ENOUGH_SEEDS = "Game.Trade.Fail.NotEnoughSeeds",
			NOT_ENOUGH_ITEMS = "Game.Trade.Fail.NotEnoughItems",
			INVALID_CREATURE = "Game.Trade.Fail.InvalidCreature",
			A_CREATURES_FULL = "Game.Trade.Fail.ACreaturesFull",
			B_CREATURES_FULL = "Game.Trade.Fail.BCreaturesFull",
			PLAYER_LEFT = "Game.Trade.Fail.PlayerLeft",
		}
		local key = failKeys[reason]
		local msg = if key then L(key) else L("Game.Trade.Fail.Default", { reason = reason })
		notify("error", L("Game.Trade.FailedTitle"), msg)
	end)
end

-- Harvest result (coin gain confirmation)
local RE_HarvestResult = waitRemote("RE_HarvestResult")
if RE_HarvestResult then
	RE_HarvestResult.OnClientEvent:Connect(function(_plotIndex: number, seedId: string, mutation: string?, coinValue: number, _newCoins: number)
		local plant = PlantData[seedId]
		local name = if plant then plant.name else seedId
		local mutLabel = ""
		if mutation then
			local mutData = MutationData[mutation]
			mutLabel = if mutData then ` ({mutData.name})` else ""
		end
		notify("harvest", L("Game.Harvest.Harvested", { plant = name, mutation = mutLabel }), L("Game.Harvest.Earned", { coins = coinValue }), 3)
	end)
end

-- Creature level up
local RE_CreatureLevelUp = waitRemote("RE_CreatureLevelUp")
if RE_CreatureLevelUp then
	RE_CreatureLevelUp.OnClientEvent:Connect(function(_creatureIndex: number, newLevel: number, info)
		local name = if info and info.name then info.name else "Creature"
		local evolveHint = if info and info.canEvolve then L("Game.Creature.ReadyToEvolve") else ""
		notify("levelup", L("Game.Creature.LevelUpTitle"), L("Game.Creature.LevelUpBody", { name = name, level = newLevel }) .. evolveHint)
	end)
end

-- Creature hatch result
local RE_HatchResult = waitRemote("RE_HatchResult")
if RE_HatchResult then
	RE_HatchResult.OnClientEvent:Connect(function(success: boolean, info, errorCode: string?)
		if success and info then
			notify("creature", L("Game.Creature.HatchTitle"), L("Game.Creature.HatchBody", { rarity = info.rarity, name = info.name }), 5)
		elseif errorCode then
			local hatchKeys: { [string]: string } = {
				MAX_CREATURES = "Game.Creature.HatchFail.MaxCreatures",
				NOT_ENOUGH_COINS = "Game.Creature.HatchFail.NotEnoughCoins",
				ROLL_FAILED = "Game.Creature.HatchFail.RollFailed",
			}
			local key = hatchKeys[errorCode] or "Game.Creature.HatchFail.Default"
			notify("error", "Hatch Failed", L(key))
		end
	end)
end

-- Creature evolution result
local RE_EvolveResult = waitRemote("RE_EvolveResult")
if RE_EvolveResult then
	RE_EvolveResult.OnClientEvent:Connect(function(success: boolean, _creatureIndex: number, errorCode: string?, info)
		if success and info then
			notify("creature", L("Game.Creature.EvolveTitle"), L("Game.Creature.EvolveBody", { name = info.evolvedName }), 5)
		elseif errorCode then
			local evolveKeys: { [string]: string } = {
				ALREADY_EVOLVED = "Game.Creature.EvolveFail.AlreadyEvolved",
				LEVEL_TOO_LOW = "Game.Creature.EvolveFail.LevelTooLow",
				NOT_ENOUGH_COINS = "Game.Creature.EvolveFail.NotEnoughCoins",
			}
			local key = evolveKeys[errorCode] or "Game.Creature.EvolveFail.Default"
			notify("error", "Evolution Failed", L(key))
		end
	end)
end

-- Server-wide announcements (uses a generic remote)
local RE_Announcement = waitRemote("RE_Announcement")
if RE_Announcement then
	RE_Announcement.OnClientEvent:Connect(function(title: string, body: string, duration: number?)
		notify("announcement", title, body, duration)
	end)
end
