-- GardenUI: Main gameplay interface for Bloom Island.
-- Renders plant plots, seed selector, harvest flow, coin display,
-- weather indicator, and creature panel. All logic is display-only;
-- game state lives on the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local MutationData = require(Shared.Config.MutationData)
local CreatureData = require(Shared.Config.CreatureData)
local GameConfig = require(Shared.Config.GameConfig)
local L = require(Shared.Localization)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Remote References
--------------------------------------------------------------------------------

local RE_PlantSeed = Remotes:WaitForChild("RE_PlantSeed")
local RE_HarvestPlant = Remotes:WaitForChild("RE_HarvestPlant")
local RE_PlotUpdated = Remotes:WaitForChild("RE_PlotUpdated")
local RE_PlantGrown = Remotes:WaitForChild("RE_PlantGrown")
local RE_MutationRolled = Remotes:WaitForChild("RE_MutationRolled")
local RE_HarvestResult = Remotes:WaitForChild("RE_HarvestResult")
local RF_GetPlots = Remotes:WaitForChild("RF_GetPlots")
local RE_WeatherChanged = Remotes:WaitForChild("RE_WeatherChanged")
local RF_GetWeather = Remotes:WaitForChild("RF_GetWeather")
local RF_GetCreatures = Remotes:WaitForChild("RF_GetCreatures")

--------------------------------------------------------------------------------
-- Color Palette
--------------------------------------------------------------------------------

local Colors = {
	bg = Color3.fromRGB(245, 240, 230),          -- warm cream
	panel = Color3.fromRGB(255, 255, 255),        -- white
	panelAlt = Color3.fromRGB(248, 248, 245),     -- off-white
	accent = Color3.fromRGB(76, 175, 80),         -- garden green
	accentDark = Color3.fromRGB(56, 142, 60),     -- darker green
	accentLight = Color3.fromRGB(200, 230, 201),  -- light green
	gold = Color3.fromRGB(255, 193, 7),           -- coin gold
	goldDark = Color3.fromRGB(255, 160, 0),       -- dark gold
	text = Color3.fromRGB(33, 33, 33),            -- near black
	textMuted = Color3.fromRGB(117, 117, 117),    -- gray
	textLight = Color3.fromRGB(255, 255, 255),    -- white
	border = Color3.fromRGB(224, 224, 224),        -- light gray
	plotEmpty = Color3.fromRGB(188, 170, 140),     -- earthy tan
	plotGrowing = Color3.fromRGB(139, 195, 74),    -- lime green
	plotReady = Color3.fromRGB(76, 175, 80),       -- green
	plotMutated = Color3.fromRGB(255, 215, 0),     -- gold shimmer
	danger = Color3.fromRGB(244, 67, 54),          -- red
	tierCommon = Color3.fromRGB(158, 158, 158),
	tierUncommon = Color3.fromRGB(76, 175, 80),
	tierRare = Color3.fromRGB(33, 150, 243),
	tierEpic = Color3.fromRGB(156, 39, 176),
	tierLegendary = Color3.fromRGB(255, 152, 0),
}

local TIER_COLORS: { [string]: Color3 } = {
	Common = Colors.tierCommon,
	Uncommon = Colors.tierUncommon,
	Rare = Colors.tierRare,
	Epic = Colors.tierEpic,
	Legendary = Colors.tierLegendary,
}

local WEATHER_ICONS: { [string]: string } = {
	sunny = "☀️",
	rainy = "🌧️",
	stormy = "⛈️",
	northernLights = "🌌",
	solarEclipse = "🌑",
	meteorShower = "☄️",
}

local WEATHER_LABEL_KEYS: { [string]: string } = {
	sunny = "Game.Weather.Sunny",
	rainy = "Game.Weather.Rainy",
	stormy = "Game.Weather.Stormy",
	northernLights = "Game.Weather.NorthernLights",
	solarEclipse = "Game.Weather.SolarEclipse",
	meteorShower = "Game.Weather.MeteorShower",
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local plots: { [number]: any } = {}
local coins = 0
local maxPlots = GameConfig.MAX_PLOTS_BASE
local selectedSeedId: string? = nil
local currentWeather = "sunny"
local weatherTimeRemaining = 0
local creatures: { any } = {}
local creatureBonuses: { [string]: number } = {}
local creaturePanelOpen = false

-- UI element references
local plotFrames: { [number]: Frame } = {}
local seedButtons: { [string]: Frame } = {}

--------------------------------------------------------------------------------
-- UI Factory Helpers
--------------------------------------------------------------------------------

local function create(className: string, props: { [string]: any }): Instance
	local instance = Instance.new(className)
	local children = {}
	for key, value in props do
		if typeof(value) == "Instance" then
			value.Parent = instance
		elseif key == "Children" then
			children = value
		else
			(instance :: any)[key] = value
		end
	end
	for _, child in children do
		child.Parent = instance
	end
	return instance
end

local function addCorner(parent: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = parent
	return corner
end

local function addStroke(parent: Instance, color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Colors.border
	stroke.Thickness = thickness or 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function addPadding(parent: Instance, padding: number): UIPadding
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, padding)
	pad.PaddingBottom = UDim.new(0, padding)
	pad.PaddingLeft = UDim.new(0, padding)
	pad.PaddingRight = UDim.new(0, padding)
	pad.Parent = parent
	return pad
end

local function addListLayout(parent: Instance, direction: Enum.FillDirection?, padding: number?, hAlign: Enum.HorizontalAlignment?, vAlign: Enum.VerticalAlignment?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction or Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, padding or 4)
	layout.HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = vAlign or Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

local function addGridLayout(parent: Instance, cellSize: UDim2, padding: UDim2?): UIGridLayout
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = cellSize
	grid.CellPadding = padding or UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = parent
	return grid
end

local function tweenProperty(instance: Instance, props: { [string]: any }, duration: number?, easingStyle: Enum.EasingStyle?)
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(duration or 0.3, easingStyle or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		props
	)
	tween:Play()
	return tween
end

local function formatNumber(n: number): string
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(math.floor(n))
end

local function formatTime(seconds: number): string
	if seconds <= 0 then return "Ready" end
	local m = math.floor(seconds / 60)
	local s = math.floor(seconds % 60)
	if m > 0 then
		return `{m}m {s}s`
	end
	return `{s}s`
end

--------------------------------------------------------------------------------
-- Build ScreenGui
--------------------------------------------------------------------------------

local screenGui = create("ScreenGui", {
	Name = "GardenUI",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
	Parent = playerGui,
}) :: ScreenGui

--------------------------------------------------------------------------------
-- Top Bar (Coins + Weather)
--------------------------------------------------------------------------------

local topBar = create("Frame", {
	Name = "TopBar",
	Size = UDim2.new(1, 0, 0, 52),
	Position = UDim2.fromOffset(0, 0),
	BackgroundColor3 = Colors.panel,
	BorderSizePixel = 0,
	Parent = screenGui,
}) :: Frame
addStroke(topBar, Colors.border, 1)

-- Coin display (left side)
local coinFrame = create("Frame", {
	Name = "CoinFrame",
	Size = UDim2.new(0, 180, 0, 36),
	Position = UDim2.new(0, 16, 0.5, -18),
	BackgroundColor3 = Colors.gold,
	BorderSizePixel = 0,
	Parent = topBar,
}) :: Frame
addCorner(coinFrame, 18)

local coinIcon = create("TextLabel", {
	Name = "CoinIcon",
	Size = UDim2.new(0, 30, 1, 0),
	Position = UDim2.fromOffset(6, 0),
	BackgroundTransparency = 1,
	Text = "🪙",
	TextSize = 20,
	Font = Enum.Font.GothamBold,
	TextColor3 = Colors.text,
	Parent = coinFrame,
})

local coinLabel = create("TextLabel", {
	Name = "CoinLabel",
	Size = UDim2.new(1, -44, 1, 0),
	Position = UDim2.fromOffset(36, 0),
	BackgroundTransparency = 1,
	Text = "0",
	TextSize = 18,
	Font = Enum.Font.GothamBold,
	TextColor3 = Colors.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = coinFrame,
}) :: TextLabel

-- Weather indicator (center)
local weatherFrame = create("Frame", {
	Name = "WeatherFrame",
	Size = UDim2.new(0, 220, 0, 36),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	BackgroundColor3 = Colors.panelAlt,
	BorderSizePixel = 0,
	Parent = topBar,
}) :: Frame
addCorner(weatherFrame, 18)
addStroke(weatherFrame, Colors.border)

local weatherIcon = create("TextLabel", {
	Name = "WeatherIcon",
	Size = UDim2.new(0, 30, 1, 0),
	Position = UDim2.fromOffset(8, 0),
	BackgroundTransparency = 1,
	Text = "☀️",
	TextSize = 18,
	Font = Enum.Font.Gotham,
	TextColor3 = Colors.text,
	Parent = weatherFrame,
}) :: TextLabel

local weatherLabel = create("TextLabel", {
	Name = "WeatherLabel",
	Size = UDim2.new(0, 100, 1, 0),
	Position = UDim2.fromOffset(38, 0),
	BackgroundTransparency = 1,
	Text = L("Game.Weather.Sunny"),
	TextSize = 14,
	Font = Enum.Font.GothamMedium,
	TextColor3 = Colors.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = weatherFrame,
}) :: TextLabel

local weatherTimer = create("TextLabel", {
	Name = "WeatherTimer",
	Size = UDim2.new(0, 60, 1, 0),
	Position = UDim2.new(1, -68, 0, 0),
	BackgroundTransparency = 1,
	Text = "5:00",
	TextSize = 13,
	Font = Enum.Font.GothamMedium,
	TextColor3 = Colors.textMuted,
	TextXAlignment = Enum.TextXAlignment.Right,
	Parent = weatherFrame,
}) :: TextLabel

-- Creature panel toggle (right side)
local creatureToggle = create("TextButton", {
	Name = "CreatureToggle",
	Size = UDim2.new(0, 120, 0, 36),
	Position = UDim2.new(1, -136, 0.5, -18),
	BackgroundColor3 = Colors.accent,
	BorderSizePixel = 0,
	Text = L("UI.TopBar.Creatures"),
	TextSize = 14,
	Font = Enum.Font.GothamBold,
	TextColor3 = Colors.textLight,
	Parent = topBar,
}) :: TextButton
addCorner(creatureToggle, 18)

--------------------------------------------------------------------------------
-- Plot Grid (center area)
--------------------------------------------------------------------------------

local plotContainer = create("Frame", {
	Name = "PlotContainer",
	Size = UDim2.new(1, -32, 0, 320),
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 68),
	BackgroundTransparency = 1,
	Parent = screenGui,
}) :: Frame

local plotGrid = create("Frame", {
	Name = "PlotGrid",
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundTransparency = 1,
	Parent = plotContainer,
}) :: Frame
addGridLayout(plotGrid, UDim2.fromOffset(140, 160), UDim2.fromOffset(12, 12))

local function getMutationColor(mutationId: string): Color3
	local mutData = MutationData[mutationId]
	if mutData then
		return mutData.particleColor
	end
	return Colors.plotReady
end

local function buildPlotFrame(index: number): Frame
	local frame = create("Frame", {
		Name = `Plot_{index}`,
		BackgroundColor3 = Colors.plotEmpty,
		BorderSizePixel = 0,
		LayoutOrder = index,
		Parent = plotGrid,
	}) :: Frame
	addCorner(frame, 12)
	addStroke(frame, Colors.border, 2)

	-- Plant icon / empty label
	local plantLabel = create("TextLabel", {
		Name = "PlantLabel",
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromOffset(0, 12),
		BackgroundTransparency = 1,
		Text = "🌱",
		TextSize = 32,
		Font = Enum.Font.Gotham,
		TextColor3 = Colors.text,
		Parent = frame,
	}) :: TextLabel

	-- Plant name
	local nameLabel = create("TextLabel", {
		Name = "NameLabel",
		Size = UDim2.new(1, -12, 0, 18),
		Position = UDim2.new(0, 6, 0, 56),
		BackgroundTransparency = 1,
		Text = L("UI.Plot.EmptyPlot"),
		TextSize = 13,
		Font = Enum.Font.GothamMedium,
		TextColor3 = Colors.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	}) :: TextLabel

	-- Progress bar background
	local progressBg = create("Frame", {
		Name = "ProgressBg",
		Size = UDim2.new(1, -16, 0, 8),
		Position = UDim2.new(0, 8, 0, 80),
		BackgroundColor3 = Colors.border,
		BorderSizePixel = 0,
		Visible = false,
		Parent = frame,
	}) :: Frame
	addCorner(progressBg, 4)

	-- Progress bar fill
	local progressFill = create("Frame", {
		Name = "ProgressFill",
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Colors.accent,
		BorderSizePixel = 0,
		Parent = progressBg,
	}) :: Frame
	addCorner(progressFill, 4)

	-- Status / timer text
	local statusLabel = create("TextLabel", {
		Name = "StatusLabel",
		Size = UDim2.new(1, -12, 0, 16),
		Position = UDim2.new(0, 6, 0, 94),
		BackgroundTransparency = 1,
		Text = "",
		TextSize = 11,
		Font = Enum.Font.Gotham,
		TextColor3 = Colors.textMuted,
		Parent = frame,
	}) :: TextLabel

	-- Mutation badge
	local mutationBadge = create("TextLabel", {
		Name = "MutationBadge",
		Size = UDim2.new(0, 60, 0, 20),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 114),
		BackgroundColor3 = Colors.gold,
		BorderSizePixel = 0,
		Text = "",
		TextSize = 10,
		Font = Enum.Font.GothamBold,
		TextColor3 = Colors.text,
		Visible = false,
		Parent = frame,
	}) :: TextLabel
	addCorner(mutationBadge, 10)

	-- Harvest button
	local harvestBtn = create("TextButton", {
		Name = "HarvestBtn",
		Size = UDim2.new(1, -16, 0, 28),
		Position = UDim2.new(0, 8, 1, -36),
		BackgroundColor3 = Colors.accent,
		BorderSizePixel = 0,
		Text = L("UI.Plot.Harvest"),
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextColor3 = Colors.textLight,
		Visible = false,
		Parent = frame,
	}) :: TextButton
	addCorner(harvestBtn, 6)

	-- Click handler: plant if empty, harvest if ready
	frame.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local plot = plots[index]
		if not plot or not plot.seedId then
			-- Empty plot: plant selected seed
			if selectedSeedId then
				RE_PlantSeed:FireServer(index, selectedSeedId)
			end
		end
	end)

	harvestBtn.Activated:Connect(function()
		RE_HarvestPlant:FireServer(index)
	end)

	plotFrames[index] = frame
	return frame
end

-- Build initial plots
local function rebuildPlotGrid()
	-- Remove excess plots
	for i, frame in plotFrames do
		if i > maxPlots then
			frame:Destroy()
			plotFrames[i] = nil
		end
	end
	-- Add missing plots
	for i = 1, maxPlots do
		if not plotFrames[i] then
			buildPlotFrame(i)
		end
	end
end

--------------------------------------------------------------------------------
-- Plot Rendering
--------------------------------------------------------------------------------

local PLANT_EMOJIS: { [string]: { growing: string, ready: string } } = {
	daisy = { growing = "🌱", ready = "🌼" },
	tulip = { growing = "🌱", ready = "🌷" },
	rose = { growing = "🪴", ready = "🌹" },
	sunflower = { growing = "🪴", ready = "🌻" },
	bonsai = { growing = "🪴", ready = "🌳" },
	orchid = { growing = "🪴", ready = "🪻" },
}

local function renderPlot(index: number)
	local frame = plotFrames[index]
	if not frame then return end

	local plot = plots[index]
	local plantLabel = frame:FindFirstChild("PlantLabel") :: TextLabel
	local nameLabel = frame:FindFirstChild("NameLabel") :: TextLabel
	local progressBg = frame:FindFirstChild("ProgressBg") :: Frame
	local progressFill = progressBg and progressBg:FindFirstChild("ProgressFill") :: Frame
	local statusLabel = frame:FindFirstChild("StatusLabel") :: TextLabel
	local mutationBadge = frame:FindFirstChild("MutationBadge") :: TextLabel
	local harvestBtn = frame:FindFirstChild("HarvestBtn") :: TextButton

	if not plot or not plot.seedId then
		-- Empty plot
		frame.BackgroundColor3 = Colors.plotEmpty
		plantLabel.Text = if selectedSeedId then "+" else "🌱"
		plantLabel.TextSize = if selectedSeedId then 36 else 32
		nameLabel.Text = if selectedSeedId then L("UI.Plot.TapToPlant") else L("UI.Plot.EmptyPlot")
		nameLabel.TextColor3 = Colors.textMuted
		progressBg.Visible = false
		statusLabel.Text = ""
		mutationBadge.Visible = false
		harvestBtn.Visible = false
		return
	end

	local plantInfo = PlantData[plot.seedId]
	local emojis = PLANT_EMOJIS[plot.seedId]
	local progress = plot.growthProgress or 0
	local isReady = progress >= 1

	-- Background color
	if plot.mutation then
		frame.BackgroundColor3 = getMutationColor(plot.mutation)
	elseif isReady then
		frame.BackgroundColor3 = Colors.plotReady
	else
		frame.BackgroundColor3 = Colors.plotGrowing
	end

	-- Plant icon
	if emojis then
		plantLabel.Text = if isReady then emojis.ready else emojis.growing
	end
	plantLabel.TextSize = 32

	-- Name
	nameLabel.Text = if plantInfo then plantInfo.name else plot.seedId
	nameLabel.TextColor3 = Colors.text

	-- Progress bar
	if isReady then
		progressBg.Visible = false
	else
		progressBg.Visible = true
		if progressFill then
			tweenProperty(progressFill, { Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0) }, 0.5)
		end
	end

	-- Status text
	if isReady then
		statusLabel.Text = L("UI.Plot.ReadyToHarvest")
		statusLabel.TextColor3 = Colors.accentDark
	elseif plantInfo then
		local remaining = plantInfo.growTime * (1 - progress)
		statusLabel.Text = formatTime(remaining)
		statusLabel.TextColor3 = Colors.textMuted
	end

	-- Mutation badge
	if plot.mutation then
		local mutData = MutationData[plot.mutation]
		mutationBadge.Visible = true
		mutationBadge.Text = if mutData then mutData.name else plot.mutation
		mutationBadge.BackgroundColor3 = getMutationColor(plot.mutation)
	else
		mutationBadge.Visible = false
	end

	-- Harvest button
	harvestBtn.Visible = isReady
end

local function renderAllPlots()
	for i = 1, maxPlots do
		renderPlot(i)
	end
end

--------------------------------------------------------------------------------
-- Seed Selector (bottom bar)
--------------------------------------------------------------------------------

local seedBar = create("Frame", {
	Name = "SeedBar",
	Size = UDim2.new(1, 0, 0, 110),
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = Colors.panel,
	BorderSizePixel = 0,
	Parent = screenGui,
}) :: Frame
addStroke(seedBar, Colors.border, 1)

local seedBarTitle = create("TextLabel", {
	Name = "Title",
	Size = UDim2.new(1, 0, 0, 22),
	Position = UDim2.fromOffset(16, 4),
	BackgroundTransparency = 1,
	Text = L("UI.Seeds.Title"),
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	TextColor3 = Colors.textMuted,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = seedBar,
})

local seedScroll = create("ScrollingFrame", {
	Name = "SeedScroll",
	Size = UDim2.new(1, -16, 0, 76),
	Position = UDim2.fromOffset(8, 28),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 0,
	ScrollingDirection = Enum.ScrollingDirection.X,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.X,
	Parent = seedBar,
}) :: ScrollingFrame
addListLayout(seedScroll, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)

-- Build sorted seed list (by cost ascending)
local sortedSeeds: { { id: string, data: any } } = {}
for seedId, data in PlantData do
	table.insert(sortedSeeds, { id = seedId, data = data })
end
table.sort(sortedSeeds, function(a, b)
	return a.data.cost < b.data.cost
end)

local function updateSeedSelection()
	for seedId, btn in seedButtons do
		local isSelected = seedId == selectedSeedId
		local tierColor = TIER_COLORS[PlantData[seedId].tier] or Colors.tierCommon
		local stroke = btn:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if isSelected then tierColor else Colors.border
			stroke.Thickness = if isSelected then 3 else 1
		end
		btn.BackgroundColor3 = if isSelected then Colors.accentLight else Colors.panel
	end
	-- Re-render empty plots to show "Tap to plant" hint
	renderAllPlots()
end

for _, entry in sortedSeeds do
	local seedId = entry.id
	local data = entry.data
	local tierColor = TIER_COLORS[data.tier] or Colors.tierCommon
	local emojis = PLANT_EMOJIS[seedId]

	local btn = create("Frame", {
		Name = `Seed_{seedId}`,
		Size = UDim2.new(0, 90, 0, 70),
		BackgroundColor3 = Colors.panel,
		BorderSizePixel = 0,
		Parent = seedScroll,
	}) :: Frame
	addCorner(btn, 8)
	addStroke(btn, Colors.border)

	-- Tier color bar at top
	create("Frame", {
		Name = "TierBar",
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = tierColor,
		BorderSizePixel = 0,
		Parent = btn,
	})

	-- Plant emoji
	create("TextLabel", {
		Name = "Icon",
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.fromOffset(0, 6),
		BackgroundTransparency = 1,
		Text = if emojis then emojis.ready else "🌱",
		TextSize = 18,
		Font = Enum.Font.Gotham,
		Parent = btn,
	})

	-- Name
	create("TextLabel", {
		Name = "Name",
		Size = UDim2.new(1, -4, 0, 14),
		Position = UDim2.fromOffset(2, 30),
		BackgroundTransparency = 1,
		Text = data.name,
		TextSize = 11,
		Font = Enum.Font.GothamMedium,
		TextColor3 = Colors.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = btn,
	})

	-- Cost
	create("TextLabel", {
		Name = "Cost",
		Size = UDim2.new(1, -4, 0, 14),
		Position = UDim2.fromOffset(2, 46),
		BackgroundTransparency = 1,
		Text = if data.cost == 0 then L("UI.Seeds.Free") else `🪙 {formatNumber(data.cost)}`,
		TextSize = 11,
		Font = Enum.Font.GothamBold,
		TextColor3 = if data.cost == 0 then Colors.accent else Colors.goldDark,
		Parent = btn,
	})

	-- Click to select
	local clickDetector = create("TextButton", {
		Name = "Click",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = "",
		Parent = btn,
	}) :: TextButton

	clickDetector.Activated:Connect(function()
		if selectedSeedId == seedId then
			selectedSeedId = nil
		else
			selectedSeedId = seedId
		end
		updateSeedSelection()
	end)

	seedButtons[seedId] = btn
end

--------------------------------------------------------------------------------
-- Creature Panel (right side, toggleable)
--------------------------------------------------------------------------------

local creaturePanel = create("Frame", {
	Name = "CreaturePanel",
	Size = UDim2.new(0, 240, 0, 360),
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 260, 0, 68), -- starts off-screen
	BackgroundColor3 = Colors.panel,
	BorderSizePixel = 0,
	Parent = screenGui,
}) :: Frame
addCorner(creaturePanel, 12)
addStroke(creaturePanel, Colors.border, 2)
addPadding(creaturePanel, 12)

local creaturePanelTitle = create("TextLabel", {
	Name = "Title",
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Text = L("UI.Creatures.Title"),
	TextSize = 16,
	Font = Enum.Font.GothamBold,
	TextColor3 = Colors.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = 0,
	Parent = creaturePanel,
}) :: TextLabel

-- Bonuses summary
local bonusSummary = create("TextLabel", {
	Name = "BonusSummary",
	Size = UDim2.new(1, 0, 0, 36),
	BackgroundTransparency = 1,
	Text = L("UI.Creatures.NoBonuses"),
	TextSize = 11,
	Font = Enum.Font.Gotham,
	TextColor3 = Colors.textMuted,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextWrapped = true,
	LayoutOrder = 1,
	Parent = creaturePanel,
}) :: TextLabel

local creatureScroll = create("ScrollingFrame", {
	Name = "CreatureScroll",
	Size = UDim2.new(1, 0, 1, -68),
	Position = UDim2.fromOffset(0, 68),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = Colors.border,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	LayoutOrder = 2,
	Parent = creaturePanel,
}) :: ScrollingFrame
addListLayout(creatureScroll, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)

local function renderCreaturePanel()
	-- Clear existing creature cards
	for _, child in creatureScroll:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Bonus summary
	local bonusLines = {}
	if creatureBonuses.growthSpeed and creatureBonuses.growthSpeed > 0 then
		table.insert(bonusLines, L("UI.Creatures.Growth", { pct = math.floor(creatureBonuses.growthSpeed * 100) }))
	end
	if creatureBonuses.coinValue and creatureBonuses.coinValue > 0 then
		table.insert(bonusLines, L("UI.Creatures.Coins", { pct = math.floor(creatureBonuses.coinValue * 100) }))
	end
	if creatureBonuses.mutationLuck and creatureBonuses.mutationLuck > 0 then
		table.insert(bonusLines, L("UI.Creatures.Mutation", { pct = math.floor(creatureBonuses.mutationLuck * 100) }))
	end
	bonusSummary.Text = if #bonusLines > 0 then table.concat(bonusLines, "  •  ") else L("UI.Creatures.NoBonuses")

	if #creatures == 0 then
		create("TextLabel", {
			Name = "Empty",
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundTransparency = 1,
			Text = L("UI.Creatures.Empty"),
			TextSize = 12,
			Font = Enum.Font.Gotham,
			TextColor3 = Colors.textMuted,
			Parent = creatureScroll,
		})
		return
	end

	for i, creature in creatures do
		local rarityColor = TIER_COLORS[creature.rarity] or Colors.tierCommon

		local card = create("Frame", {
			Name = `Creature_{i}`,
			Size = UDim2.new(1, 0, 0, 64),
			BackgroundColor3 = Colors.panelAlt,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Parent = creatureScroll,
		}) :: Frame
		addCorner(card, 8)
		addStroke(card, rarityColor)

		-- Name + level
		create("TextLabel", {
			Name = "Name",
			Size = UDim2.new(1, -8, 0, 18),
			Position = UDim2.fromOffset(8, 4),
			BackgroundTransparency = 1,
			Text = `{creature.name}`,
			TextSize = 13,
			Font = Enum.Font.GothamBold,
			TextColor3 = Colors.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = card,
		})

		-- Level + rarity badge
		create("TextLabel", {
			Name = "Level",
			Size = UDim2.new(1, -8, 0, 14),
			Position = UDim2.fromOffset(8, 22),
			BackgroundTransparency = 1,
			Text = `Lv.{creature.level}  •  {creature.rarity}{if creature.evolved then "  ★" else ""}`,
			TextSize = 11,
			Font = Enum.Font.Gotham,
			TextColor3 = rarityColor,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = card,
		})

		-- XP bar
		local xpBg = create("Frame", {
			Name = "XPBg",
			Size = UDim2.new(1, -16, 0, 6),
			Position = UDim2.fromOffset(8, 40),
			BackgroundColor3 = Colors.border,
			BorderSizePixel = 0,
			Parent = card,
		}) :: Frame
		addCorner(xpBg, 3)

		local xpRange = creature.xpForNext - creature.xpForCurrent
		local xpProgress = if xpRange > 0 then math.clamp((creature.xp - creature.xpForCurrent) / xpRange, 0, 1) else 1

		local xpFill = create("Frame", {
			Name = "XPFill",
			Size = UDim2.new(xpProgress, 0, 1, 0),
			BackgroundColor3 = rarityColor,
			BorderSizePixel = 0,
			Parent = xpBg,
		}) :: Frame
		addCorner(xpFill, 3)

		-- Bonus text
		create("TextLabel", {
			Name = "Bonus",
			Size = UDim2.new(1, -8, 0, 14),
			Position = UDim2.fromOffset(8, 48),
			BackgroundTransparency = 1,
			Text = `{creature.bonusType}: +{if creature.evolved then "★ " else ""}{formatNumber(creature.xp)} XP`,
			TextSize = 10,
			Font = Enum.Font.Gotham,
			TextColor3 = Colors.textMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = card,
		})
	end
end

-- Toggle creature panel
local function toggleCreaturePanel()
	creaturePanelOpen = not creaturePanelOpen
	local targetX = if creaturePanelOpen then -16 else 260
	tweenProperty(creaturePanel, { Position = UDim2.new(1, targetX, 0, 68) }, 0.3, Enum.EasingStyle.Back)
	creatureToggle.Text = if creaturePanelOpen then L("UI.TopBar.Close") else L("UI.TopBar.Creatures")
end

creatureToggle.Activated:Connect(toggleCreaturePanel)

--------------------------------------------------------------------------------
-- Coin Animation (floating +coins text)
--------------------------------------------------------------------------------

local function playCoinAnimation(amount: number, plotIndex: number)
	local frame = plotFrames[plotIndex]
	if not frame then return end

	local absPos = frame.AbsolutePosition
	local absSize = frame.AbsoluteSize

	local floater = create("TextLabel", {
		Name = "CoinFloat",
		Size = UDim2.fromOffset(120, 30),
		Position = UDim2.fromOffset(absPos.X + absSize.X / 2 - 60, absPos.Y),
		BackgroundTransparency = 1,
		Text = `+{formatNumber(amount)} 🪙`,
		TextSize = 22,
		Font = Enum.Font.GothamBold,
		TextColor3 = Colors.gold,
		TextStrokeColor3 = Colors.text,
		TextStrokeTransparency = 0.5,
		Parent = screenGui,
	}) :: TextLabel

	-- Animate up and fade
	tweenProperty(floater, {
		Position = UDim2.fromOffset(absPos.X + absSize.X / 2 - 60, absPos.Y - 80),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}, 1.2, Enum.EasingStyle.Quad)

	task.delay(1.3, function()
		floater:Destroy()
	end)

	-- Pulse the coin display
	tweenProperty(coinFrame, { Size = UDim2.new(0, 200, 0, 40) }, 0.15)
	task.delay(0.15, function()
		tweenProperty(coinFrame, { Size = UDim2.new(0, 180, 0, 36) }, 0.2)
	end)
end

--------------------------------------------------------------------------------
-- Mutation Celebration
--------------------------------------------------------------------------------

local function playMutationCelebration(plotIndex: number, mutationId: string)
	local frame = plotFrames[plotIndex]
	if not frame then return end

	local mutData = MutationData[mutationId]
	local color = if mutData then mutData.particleColor else Colors.gold
	local name = if mutData then mutData.name else mutationId

	-- Flash the plot
	local originalColor = frame.BackgroundColor3
	for i = 1, 4 do
		task.delay((i - 1) * 0.15, function()
			frame.BackgroundColor3 = if i % 2 == 1 then color else originalColor
		end)
	end
	task.delay(0.6, function()
		renderPlot(plotIndex)
	end)

	-- Show mutation name banner
	local absPos = frame.AbsolutePosition
	local absSize = frame.AbsoluteSize

	local banner = create("TextLabel", {
		Name = "MutationBanner",
		Size = UDim2.fromOffset(160, 28),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(absPos.X + absSize.X / 2, absPos.Y + absSize.Y / 2),
		BackgroundColor3 = color,
		Text = `✨ {name}! ✨`,
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		TextColor3 = Colors.text,
		Parent = screenGui,
	}) :: TextLabel
	addCorner(banner, 14)

	tweenProperty(banner, { TextTransparency = 1, BackgroundTransparency = 1, Size = UDim2.fromOffset(200, 36) }, 2)
	task.delay(2.1, function()
		banner:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- Weather Updates
--------------------------------------------------------------------------------

local function updateWeatherDisplay()
	weatherIcon.Text = WEATHER_ICONS[currentWeather] or "☀️"
	local labelKey = WEATHER_LABEL_KEYS[currentWeather]
	weatherLabel.Text = if labelKey then L(labelKey) else currentWeather
end

RE_WeatherChanged.OnClientEvent:Connect(function(newWeather: string, _previousWeather: string?, timeRemaining: number?)
	currentWeather = newWeather
	if timeRemaining then
		weatherTimeRemaining = timeRemaining
	end
	updateWeatherDisplay()
end)

-- Weather timer countdown
task.spawn(function()
	while true do
		task.wait(1)
		if weatherTimeRemaining > 0 then
			weatherTimeRemaining -= 1
		end
		local m = math.floor(weatherTimeRemaining / 60)
		local s = math.floor(weatherTimeRemaining % 60)
		weatherTimer.Text = string.format("%d:%02d", m, s)
	end
end)

--------------------------------------------------------------------------------
-- Server Event Handlers
--------------------------------------------------------------------------------

RE_PlotUpdated.OnClientEvent:Connect(function(plotIndex: number, plotData, newCoins: number)
	plots[plotIndex] = plotData
	coins = newCoins
	coinLabel.Text = formatNumber(coins)
	renderPlot(plotIndex)
end)

RE_PlantGrown.OnClientEvent:Connect(function(plotIndex: number, _seedId: string)
	local plot = plots[plotIndex]
	if plot then
		plot.growthProgress = 1
	end
	renderPlot(plotIndex)
end)

RE_MutationRolled.OnClientEvent:Connect(function(plotIndex: number, mutationId: string)
	local plot = plots[plotIndex]
	if plot then
		plot.mutation = mutationId
	end
	renderPlot(plotIndex)
	playMutationCelebration(plotIndex, mutationId)
end)

RE_HarvestResult.OnClientEvent:Connect(function(plotIndex: number, _seedId: string, _mutation: string?, coinValue: number, newCoins: number)
	playCoinAnimation(coinValue, plotIndex)
	plots[plotIndex] = nil
	coins = newCoins
	coinLabel.Text = formatNumber(coins)
	renderPlot(plotIndex)
end)

--------------------------------------------------------------------------------
-- Growth Progress Update Loop
--------------------------------------------------------------------------------

local growthTickElapsed = 0
RunService.Heartbeat:Connect(function(dt: number)
	growthTickElapsed += dt
	if growthTickElapsed < 1 then return end
	growthTickElapsed -= 1

	-- Client-side progress estimation for smooth UI
	for i = 1, maxPlots do
		local plot = plots[i]
		if not plot or not plot.seedId then continue end
		if plot.growthProgress >= 1 then continue end

		local plantInfo = PlantData[plot.seedId]
		if not plantInfo then continue end

		-- Estimate progress increment (approximate, server is authoritative)
		local growthMult = GameConfig.WEATHER_GROWTH_MULT[currentWeather] or 1
		local increment = 1 / (plantInfo.growTime / growthMult)
		plot.growthProgress = math.min((plot.growthProgress or 0) + increment, 0.99) -- never hit 1 client-side

		renderPlot(i)
	end
end)

--------------------------------------------------------------------------------
-- Initial Data Load
--------------------------------------------------------------------------------

local function loadInitialData()
	-- Load plots
	local plotData, playerCoins, playerMaxPlots = RF_GetPlots:InvokeServer()
	if plotData then
		plots = plotData
	end
	if playerCoins then
		coins = playerCoins
		coinLabel.Text = formatNumber(coins)
	end
	if playerMaxPlots then
		maxPlots = playerMaxPlots
	end

	rebuildPlotGrid()
	renderAllPlots()

	-- Load weather
	local success, result = pcall(function()
		return { RF_GetWeather:InvokeServer() }
	end)
	if success and result then
		currentWeather = result[1] or "sunny"
		weatherTimeRemaining = result[2] or 0
		updateWeatherDisplay()
	end

	-- Load creatures
	local creatureSuccess, creatureResult = pcall(function()
		return { RF_GetCreatures:InvokeServer() }
	end)
	if creatureSuccess and creatureResult then
		creatures = creatureResult[1] or {}
		creatureBonuses = creatureResult[2] or {}
		renderCreaturePanel()
	end
end

task.spawn(loadInitialData)
