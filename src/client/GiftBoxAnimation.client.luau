-- GiftBoxAnimation: Animated gift box overlay for sending and receiving gifts.
-- Shows a wrapped gift box that opens with particle effects and reveals contents.
-- Triggers NotificationSystem toasts for gift details.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local L = require(Shared.Localization)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_GiftAnimation = Remotes:WaitForChild("RE_GiftAnimation")
local RE_GiftReceived = Remotes:WaitForChild("RE_GiftReceived")
local RE_GiftSent = Remotes:WaitForChild("RE_GiftSent")
local RE_DailyQuestUpdate = Remotes:WaitForChild("RE_DailyQuestUpdate")
local RE_DailyRewardClaimed = Remotes:WaitForChild("RE_DailyRewardClaimed")

-- NotificationSystem BindableEvent (fires toasts)
local notifyEvent: BindableEvent? = Remotes:FindFirstChild("NotifyEvent") :: BindableEvent?

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local BOX_SIZE = 120
local ANIMATION_DURATION = 2.5

local COLORS = {
	boxSend = Color3.fromRGB(76, 175, 80),      -- green
	boxReceive = Color3.fromRGB(233, 30, 99),    -- pink
	ribbon = Color3.fromRGB(255, 235, 59),       -- yellow
	ribbonSend = Color3.fromRGB(255, 255, 255),  -- white
	sparkle = Color3.fromRGB(255, 215, 0),       -- gold
	overlay = Color3.fromRGB(0, 0, 0),
}

--------------------------------------------------------------------------------
-- ScreenGui
--------------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "GiftAnimationGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 20
screenGui.Parent = playerGui

--------------------------------------------------------------------------------
-- Tween Helper
--------------------------------------------------------------------------------

local function tween(instance: Instance, props: { [string]: any }, duration: number, style: Enum.EasingStyle?, direction: Enum.EasingDirection?)
	local t = TweenService:Create(
		instance,
		TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

--------------------------------------------------------------------------------
-- Create Particle Burst (UI-based sparkles)
--------------------------------------------------------------------------------

local function spawnSparkles(parent: Frame, count: number, color: Color3)
	for i = 1, count do
		local sparkle = Instance.new("Frame")
		sparkle.Name = "Sparkle"
		sparkle.Size = UDim2.fromOffset(4 + math.random() * 4, 4 + math.random() * 4)
		sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
		sparkle.Position = UDim2.new(0.5, 0, 0.5, 0)
		sparkle.BackgroundColor3 = Color3.new(
			math.min(color.R + math.random() * 0.2, 1),
			math.min(color.G + math.random() * 0.2, 1),
			math.min(color.B + math.random() * 0.2, 1)
		)
		sparkle.BorderSizePixel = 0
		sparkle.Rotation = math.random() * 360
		sparkle.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = sparkle

		-- Burst outward
		local angle = math.rad((i / count) * 360 + math.random() * 30)
		local dist = 60 + math.random() * 80
		local targetX = 0.5 + math.cos(angle) * dist / BOX_SIZE
		local targetY = 0.5 + math.sin(angle) * dist / BOX_SIZE

		tween(sparkle, {
			Position = UDim2.new(targetX, 0, targetY, 0),
			Size = UDim2.fromOffset(2, 2),
			BackgroundTransparency = 1,
			Rotation = math.random() * 720,
		}, 0.8 + math.random() * 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		task.delay(1.3, function()
			sparkle:Destroy()
		end)
	end
end

--------------------------------------------------------------------------------
-- Gift Box Animation
--------------------------------------------------------------------------------

local animationPlaying = false

local function playGiftAnimation(mode: string, info: { [string]: any }?)
	if animationPlaying then return end
	animationPlaying = true

	local isReceive = mode == "receive"
	local boxColor = if isReceive then COLORS.boxReceive else COLORS.boxSend
	local ribbonColor = if isReceive then COLORS.ribbon else COLORS.ribbonSend
	local personName = if info then (info.fromName or info.targetName or "") else ""

	-- Dim overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "GiftOverlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = COLORS.overlay
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 1
	overlay.Parent = screenGui
	tween(overlay, { BackgroundTransparency = 0.5 }, 0.3)

	-- Container for the gift box (centered)
	local container = Instance.new("Frame")
	container.Name = "GiftContainer"
	container.Size = UDim2.fromOffset(BOX_SIZE * 2, BOX_SIZE * 2.5)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.BackgroundTransparency = 1
	container.ZIndex = 2
	container.Parent = screenGui

	-- Label: "Gift from X" / "Sending gift to X"
	local label = Instance.new("TextLabel")
	label.Name = "GiftLabel"
	label.Size = UDim2.new(1, 0, 0, 24)
	label.Position = UDim2.new(0, 0, 0, 0)
	label.AnchorPoint = Vector2.new(0, 0)
	label.BackgroundTransparency = 1
	label.Text = if isReceive then L("Game.Gift.ReceivedTitle", { name = personName }) else L("Game.Gift.SendingTo", { name = personName })
	label.TextSize = 18
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 1
	label.ZIndex = 3
	label.Parent = container
	tween(label, { TextTransparency = 0 }, 0.4)

	-- Box body
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.Size = UDim2.fromOffset(0, 0)
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.new(0.5, 0, 0.55, 0)
	box.BackgroundColor3 = boxColor
	box.BorderSizePixel = 0
	box.ZIndex = 3
	box.Parent = container

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 12)
	boxCorner.Parent = box

	-- Box lid (separate frame above the box)
	local lid = Instance.new("Frame")
	lid.Name = "Lid"
	lid.Size = UDim2.fromOffset(0, 0)
	lid.AnchorPoint = Vector2.new(0.5, 1)
	lid.Position = UDim2.new(0.5, 0, 0, 0)
	lid.BackgroundColor3 = Color3.new(
		math.max(boxColor.R - 0.1, 0),
		math.max(boxColor.G - 0.1, 0),
		math.max(boxColor.B - 0.1, 0)
	)
	lid.BorderSizePixel = 0
	lid.ZIndex = 4
	lid.Parent = box

	local lidCorner = Instance.new("UICorner")
	lidCorner.CornerRadius = UDim.new(0, 10)
	lidCorner.Parent = lid

	-- Horizontal ribbon (across box center)
	local hRibbon = Instance.new("Frame")
	hRibbon.Name = "HRibbon"
	hRibbon.Size = UDim2.new(1, 0, 0, 10)
	hRibbon.AnchorPoint = Vector2.new(0, 0.5)
	hRibbon.Position = UDim2.new(0, 0, 0.45, 0)
	hRibbon.BackgroundColor3 = ribbonColor
	hRibbon.BorderSizePixel = 0
	hRibbon.ZIndex = 5
	hRibbon.Parent = box

	-- Vertical ribbon
	local vRibbon = Instance.new("Frame")
	vRibbon.Name = "VRibbon"
	vRibbon.Size = UDim2.new(0, 10, 1, 0)
	vRibbon.AnchorPoint = Vector2.new(0.5, 0)
	vRibbon.Position = UDim2.new(0.5, 0, 0, 0)
	vRibbon.BackgroundColor3 = ribbonColor
	vRibbon.BorderSizePixel = 0
	vRibbon.ZIndex = 5
	vRibbon.Parent = box

	-- Bow on top
	local bow = Instance.new("TextLabel")
	bow.Name = "Bow"
	bow.Size = UDim2.fromOffset(40, 30)
	bow.AnchorPoint = Vector2.new(0.5, 1)
	bow.Position = UDim2.new(0.5, 0, 0, 5)
	bow.BackgroundTransparency = 1
	bow.Text = "🎀"
	bow.TextSize = 28
	bow.TextTransparency = 1
	bow.ZIndex = 6
	bow.Parent = box

	-- Phase 1: Box appears (scale up with bounce)
	tween(box, { Size = UDim2.fromOffset(BOX_SIZE, BOX_SIZE) }, 0.5, Enum.EasingStyle.Back)
	tween(lid, { Size = UDim2.fromOffset(BOX_SIZE + 10, 25) }, 0.5, Enum.EasingStyle.Back)
	tween(bow, { TextTransparency = 0 }, 0.4)

	-- Phase 2: Wobble
	task.delay(0.6, function()
		-- Shake the box
		for i = 1, 3 do
			tween(box, { Rotation = 5 }, 0.08)
			task.wait(0.08)
			tween(box, { Rotation = -5 }, 0.08)
			task.wait(0.08)
		end
		tween(box, { Rotation = 0 }, 0.06)
	end)

	-- Phase 3: Lid pops off + sparkle burst
	task.delay(1.4, function()
		-- Lid flies up and away
		tween(lid, {
			Position = UDim2.new(0.5, 0, 0, -80),
			Rotation = 25,
			BackgroundTransparency = 1,
		}, 0.5, Enum.EasingStyle.Quad)

		tween(bow, {
			Position = UDim2.new(0.5, 0, 0, -60),
			TextTransparency = 1,
		}, 0.4)

		-- Sparkle burst from the box
		spawnSparkles(container, 20, COLORS.sparkle)

		-- Content emoji pops out
		local contentEmoji = Instance.new("TextLabel")
		contentEmoji.Name = "Content"
		contentEmoji.Size = UDim2.fromOffset(60, 60)
		contentEmoji.AnchorPoint = Vector2.new(0.5, 0.5)
		contentEmoji.Position = UDim2.new(0.5, 0, 0.45, 0)
		contentEmoji.BackgroundTransparency = 1
		contentEmoji.Text = if isReceive then "🎁" else "💝"
		contentEmoji.TextSize = 0
		contentEmoji.Font = Enum.Font.Gotham
		contentEmoji.ZIndex = 7
		contentEmoji.Parent = container

		tween(contentEmoji, {
			TextSize = 48,
			Position = UDim2.new(0.5, 0, 0.35, 0),
		}, 0.4, Enum.EasingStyle.Back)

		-- Update label
		label.Text = if isReceive then L("Game.Gift.OpenedFrom", { name = personName }) else L("Game.Gift.SentTo", { name = personName })
	end)

	-- Phase 4: Fade out
	task.delay(ANIMATION_DURATION, function()
		tween(overlay, { BackgroundTransparency = 1 }, 0.4)
		tween(container, { BackgroundTransparency = 1 }, 0.3)

		-- Fade all children
		for _, child in container:GetDescendants() do
			if child:IsA("Frame") then
				tween(child, { BackgroundTransparency = 1 }, 0.3)
			elseif child:IsA("TextLabel") then
				tween(child, { TextTransparency = 1 }, 0.3)
			end
		end

		task.delay(0.5, function()
			overlay:Destroy()
			container:Destroy()
			animationPlaying = false
		end)
	end)
end

--------------------------------------------------------------------------------
-- Event Listeners
--------------------------------------------------------------------------------

RE_GiftAnimation.OnClientEvent:Connect(function(mode: string, info)
	playGiftAnimation(mode, info)
end)

-- Gift received — also fire notification toast
RE_GiftReceived.OnClientEvent:Connect(function(giftInfo)
	if not notifyEvent then
		notifyEvent = Remotes:FindFirstChild("NotifyEvent") :: BindableEvent?
	end
	if not notifyEvent then return end

	local fromName = giftInfo.fromName or "Someone"
	local summary = giftInfo.summary

	-- Build description
	local parts = {}
	if summary and summary.seeds then
		for seedId, count in summary.seeds do
			if typeof(count) == "number" and count > 0 then
				table.insert(parts, `{count}x {seedId}`)
			elseif typeof(count) == "table" then
				-- Summary format from server: { seedId, name, count }
				table.insert(parts, `{count.count}x {count.name}`)
			end
		end
	end
	if summary and summary.creature then
		local c = summary.creature
		local name = if typeof(c) == "table" then (c.name or c.creatureId or "creature") else "creature"
		table.insert(parts, name)
	end

	local contents = if #parts > 0 then table.concat(parts, ", ") else L("Game.Gift.FallbackContents")
	local offlineNote = if giftInfo.wasOffline then L("Game.Gift.OfflineNote") else ""

	notifyEvent:Fire("gift", L("Game.Gift.ReceivedTitle", { name = fromName }), L("Game.Gift.ReceivedBody", { contents = contents, note = offlineNote }), 5)
end)

-- Gift sent confirmation toast
RE_GiftSent.OnClientEvent:Connect(function(sendInfo)
	if not notifyEvent then
		notifyEvent = Remotes:FindFirstChild("NotifyEvent") :: BindableEvent?
	end
	if not notifyEvent then return end

	local targetName = sendInfo.targetName or "someone"
	notifyEvent:Fire("gift", L("Game.Gift.SentTitle"), L("Game.Gift.SentBody", { name = targetName }), 3)
end)

-- Daily quest progress toast
RE_DailyQuestUpdate.OnClientEvent:Connect(function(questData)
	if not notifyEvent then
		notifyEvent = Remotes:FindFirstChild("NotifyEvent") :: BindableEvent?
	end
	if not notifyEvent then return end

	local progress = `{questData.giftsToday}/{questData.goal}`
	if questData.complete and not questData.claimed then
		notifyEvent:Fire("info", L("Game.Gift.DailyComplete"), L("Game.Gift.DailyCompleteBody", { goal = questData.goal, progress = progress }), 5)
	else
		notifyEvent:Fire("info", L("Game.Gift.DailyTitle"), L("Game.Gift.DailyBody", { goal = questData.goal, progress = progress }), 3)
	end
end)

-- Daily reward claimed toast
RE_DailyRewardClaimed.OnClientEvent:Connect(function(rewardData)
	if not notifyEvent then
		notifyEvent = Remotes:FindFirstChild("NotifyEvent") :: BindableEvent?
	end
	if not notifyEvent then return end

	notifyEvent:Fire("gift", L("Game.Gift.DailyRewardTitle"), L("Game.Gift.DailyRewardBody", { reward = rewardData.reward }), 5)
end)
