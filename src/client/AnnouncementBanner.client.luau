-- AnnouncementBanner: Golden banner that slides down from the top of the screen
-- for server-wide announcements (rare mutations, events, admin messages).
-- Distinct from toast notifications — large, attention-grabbing, centered.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local L = require(Shared.Localization)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_ServerAnnouncement = Remotes:WaitForChild("RE_ServerAnnouncement")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local BANNER_HEIGHT = 80
local SLIDE_IN_TIME = 0.4
local SLIDE_OUT_TIME = 0.35
local DEFAULT_DURATION = 5

local GOLD = Color3.fromRGB(255, 193, 7)
local GOLD_DARK = Color3.fromRGB(180, 130, 0)
local GOLD_LIGHT = Color3.fromRGB(255, 235, 170)
local TEXT_DARK = Color3.fromRGB(40, 30, 0)

-- Rarity shimmer accent colors (fallback to gold)
local RARITY_ACCENTS: { [string]: { bg: Color3, shimmer: Color3, text: Color3 } } = {
	cosmic = {
		bg = Color3.fromRGB(45, 20, 70),
		shimmer = Color3.fromRGB(155, 89, 182),
		text = Color3.fromRGB(220, 180, 255),
	},
	celestial = {
		bg = Color3.fromRGB(60, 20, 5),
		shimmer = Color3.fromRGB(255, 69, 0),
		text = Color3.fromRGB(255, 200, 150),
	},
	mythical = {
		bg = Color3.fromRGB(5, 40, 50),
		shimmer = Color3.fromRGB(0, 255, 255),
		text = Color3.fromRGB(180, 255, 255),
	},
	secret = {
		bg = Color3.fromRGB(50, 50, 50),
		shimmer = Color3.fromRGB(255, 255, 255),
		text = Color3.fromRGB(255, 255, 255),
	},
}

local DEFAULT_ACCENT = {
	bg = Color3.fromRGB(50, 35, 0),
	shimmer = GOLD,
	text = GOLD_LIGHT,
}

--------------------------------------------------------------------------------
-- ScreenGui
--------------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AnnouncementBannerGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 25
screenGui.Parent = playerGui

--------------------------------------------------------------------------------
-- Banner Queue (one at a time, queue the rest)
--------------------------------------------------------------------------------

local bannerActive = false
local bannerQueue: { any } = {}

local function tween(instance: Instance, props: { [string]: any }, duration: number, style: Enum.EasingStyle?, direction: Enum.EasingDirection?)
	local t = TweenService:Create(
		instance,
		TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

local function processQueue()
	-- Forward declaration; filled below
end

local function showBanner(announcement)
	bannerActive = true

	local mutationId = announcement.mutationId
	local accent = if mutationId and RARITY_ACCENTS[mutationId]
		then RARITY_ACCENTS[mutationId]
		else DEFAULT_ACCENT

	local duration = announcement.duration or DEFAULT_DURATION

	-- Override accent from server-sent color if present
	if announcement.accentColor and not RARITY_ACCENTS[mutationId or ""] then
		local c = announcement.accentColor
		if c.r and c.g and c.b then
			accent = {
				bg = Color3.fromRGB(c.r * 0.2, c.g * 0.2, c.b * 0.2),
				shimmer = Color3.fromRGB(c.r, c.g, c.b),
				text = Color3.fromRGB(
					math.min(c.r + 80, 255),
					math.min(c.g + 80, 255),
					math.min(c.b + 80, 255)
				),
			}
		end
	end

	-- Banner container — starts above screen
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.Size = UDim2.new(1, 0, 0, BANNER_HEIGHT)
	banner.Position = UDim2.new(0, 0, 0, -BANNER_HEIGHT)
	banner.BackgroundColor3 = accent.bg
	banner.BackgroundTransparency = 0.05
	banner.BorderSizePixel = 0
	banner.ZIndex = 1
	banner.Parent = screenGui

	-- Gold bottom border
	local borderLine = Instance.new("Frame")
	borderLine.Name = "Border"
	borderLine.Size = UDim2.new(1, 0, 0, 3)
	borderLine.Position = UDim2.new(0, 0, 1, -3)
	borderLine.BackgroundColor3 = accent.shimmer
	borderLine.BorderSizePixel = 0
	borderLine.ZIndex = 2
	borderLine.Parent = banner

	-- Shimmer overlay (animated gradient sweep)
	local shimmer = Instance.new("Frame")
	shimmer.Name = "Shimmer"
	shimmer.Size = UDim2.new(0.3, 0, 1, 0)
	shimmer.Position = UDim2.new(-0.3, 0, 0, 0)
	shimmer.BackgroundColor3 = accent.shimmer
	shimmer.BackgroundTransparency = 0.85
	shimmer.BorderSizePixel = 0
	shimmer.ZIndex = 2
	shimmer.Parent = banner

	-- Star icons on sides
	local starLeft = Instance.new("TextLabel")
	starLeft.Name = "StarL"
	starLeft.Size = UDim2.fromOffset(40, BANNER_HEIGHT)
	starLeft.Position = UDim2.fromOffset(20, 0)
	starLeft.BackgroundTransparency = 1
	starLeft.Text = "✦"
	starLeft.TextSize = 24
	starLeft.Font = Enum.Font.GothamBold
	starLeft.TextColor3 = accent.shimmer
	starLeft.ZIndex = 3
	starLeft.Parent = banner

	local starRight = starLeft:Clone()
	starRight.Name = "StarR"
	starRight.AnchorPoint = Vector2.new(1, 0)
	starRight.Position = UDim2.new(1, -20, 0, 0)
	starRight.Parent = banner

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -140, 0, 24)
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 12)
	title.BackgroundTransparency = 1
	title.Text = announcement.title or L("Game.Announce.Fallback")
	title.TextSize = 18
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = accent.shimmer
	title.TextTransparency = 1
	title.ZIndex = 3
	title.Parent = banner

	-- Message
	local message = Instance.new("TextLabel")
	message.Name = "Message"
	message.Size = UDim2.new(1, -140, 0, 24)
	message.AnchorPoint = Vector2.new(0.5, 0)
	message.Position = UDim2.new(0.5, 0, 0, 38)
	message.BackgroundTransparency = 1
	message.Text = announcement.message or ""
	message.TextSize = 15
	message.Font = Enum.Font.GothamMedium
	message.TextColor3 = accent.text
	message.TextTransparency = 1
	message.TextWrapped = true
	message.ZIndex = 3
	message.Parent = banner

	-- === Animation ===

	-- Slide down
	tween(banner, { Position = UDim2.new(0, 0, 0, 0) }, SLIDE_IN_TIME, Enum.EasingStyle.Back)

	-- Fade in text
	task.delay(0.15, function()
		tween(title, { TextTransparency = 0 }, 0.3)
		tween(message, { TextTransparency = 0 }, 0.3)
	end)

	-- Shimmer sweep (loop during display)
	task.spawn(function()
		local sweepCount = math.ceil(duration / 1.5)
		for i = 1, sweepCount do
			shimmer.Position = UDim2.new(-0.3, 0, 0, 0)
			tween(shimmer, { Position = UDim2.new(1, 0, 0, 0) }, 1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			task.wait(1.5)
		end
	end)

	-- Star pulse
	task.spawn(function()
		local pulseCount = math.ceil(duration / 0.8)
		for i = 1, pulseCount do
			tween(starLeft, { TextSize = 30, TextTransparency = 0 }, 0.3)
			tween(starRight, { TextSize = 30, TextTransparency = 0 }, 0.3)
			task.wait(0.4)
			tween(starLeft, { TextSize = 24, TextTransparency = 0.3 }, 0.3)
			tween(starRight, { TextSize = 24, TextTransparency = 0.3 }, 0.3)
			task.wait(0.4)
		end
	end)

	-- Hold, then slide out
	task.delay(duration, function()
		-- Fade text
		tween(title, { TextTransparency = 1 }, 0.2)
		tween(message, { TextTransparency = 1 }, 0.2)

		-- Slide up
		task.delay(0.1, function()
			local slideTween = tween(banner, {
				Position = UDim2.new(0, 0, 0, -BANNER_HEIGHT - 10),
			}, SLIDE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

			slideTween.Completed:Connect(function()
				banner:Destroy()
				bannerActive = false
				processQueue()
			end)
		end)
	end)
end

-- Process queued announcements
function processQueue()
	if bannerActive then return end
	if #bannerQueue == 0 then return end
	local next = table.remove(bannerQueue, 1)
	showBanner(next)
end

--------------------------------------------------------------------------------
-- Event Listener
--------------------------------------------------------------------------------

RE_ServerAnnouncement.OnClientEvent:Connect(function(announcement)
	if typeof(announcement) ~= "table" then return end

	if bannerActive then
		table.insert(bannerQueue, announcement)
	else
		showBanner(announcement)
	end
end)
