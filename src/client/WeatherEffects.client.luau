-- WeatherEffects: Client-side visual/audio effects for each weather type.
-- Listens for RE_WeatherChanged and transitions between effect sets.
-- Uses 3D ParticleEmitters in Workspace, UI overlays, and Lighting tweaks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_WeatherChanged = Remotes:WaitForChild("RE_WeatherChanged")

local WeatherFolder = Workspace:WaitForChild("Weather")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local TRANSITION_TIME = 1.5 -- seconds to blend between weather states
local RAIN_RATE = 200
local STORM_RAIN_RATE = 350
local LIGHTNING_MIN_INTERVAL = 4
local LIGHTNING_MAX_INTERVAL = 10
local AURORA_WAVE_COUNT = 5
local METEOR_RATE = 3 -- meteors per second
local ECLIPSE_CRACK_COUNT = 8

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local activeWeather: string = "sunny"
local activeEffects: { Instance } = {} -- all created instances, destroyed on cleanup
local activeConnections: { RBXScriptConnection } = {}
local effectRunning = false -- guards the per-weather loop

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function tweenProperty(instance: Instance, props: { [string]: any }, duration: number?)
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(duration or TRANSITION_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		props
	)
	tween:Play()
	return tween
end

local function trackInstance(instance: Instance)
	table.insert(activeEffects, instance)
end

local function trackConnection(conn: RBXScriptConnection)
	table.insert(activeConnections, conn)
end

local function createPart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.Parent = WeatherFolder
	for key, value in props do
		(part :: any)[key] = value
	end
	trackInstance(part)
	return part
end

local function createParticleEmitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Parent = parent
	for key, value in props do
		(emitter :: any)[key] = value
	end
	trackInstance(emitter)
	return emitter
end

local function getCameraPosition(): Vector3
	if camera then
		return camera.CFrame.Position
	end
	return Vector3.new(0, 50, 0)
end

--------------------------------------------------------------------------------
-- Overlay ScreenGui (for screen-space effects)
--------------------------------------------------------------------------------

local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "WeatherOverlay"
overlayGui.ResetOnSpawn = false
overlayGui.IgnoreGuiInset = true
overlayGui.DisplayOrder = 5
overlayGui.Parent = playerGui
trackInstance(overlayGui) -- won't be destroyed per-weather; managed separately

-- Reusable full-screen overlay frame
local function createOverlay(name: string, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Parent = overlayGui
	trackInstance(frame)
	return frame
end

--------------------------------------------------------------------------------
-- Lighting Presets (client-side tweens complement server Lighting changes)
--------------------------------------------------------------------------------

local function createOrGetAtmosphere(): Atmosphere
	local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmo then
		atmo = Instance.new("Atmosphere")
		atmo.Parent = Lighting
	end
	return atmo
end

local function createOrGetBloom(): BloomEffect
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if not bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Parent = Lighting
	end
	return bloom
end

local function createOrGetColorCorrection(): ColorCorrectionEffect
	local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if not cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Parent = Lighting
	end
	return cc
end

local function resetLightingEffects()
	local atmo = createOrGetAtmosphere()
	tweenProperty(atmo, {
		Density = 0.3,
		Offset = 0,
		Color = Color3.fromRGB(199, 199, 199),
		Decay = Color3.fromRGB(92, 92, 92),
		Glare = 0,
		Haze = 0,
	})

	local bloom = createOrGetBloom()
	tweenProperty(bloom, {
		Intensity = 0.4,
		Size = 24,
		Threshold = 0.95,
	})

	local cc = createOrGetColorCorrection()
	tweenProperty(cc, {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.new(1, 1, 1),
	})
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

local function cleanupEffects()
	effectRunning = false

	-- Disconnect all per-weather connections
	for _, conn in activeConnections do
		conn:Disconnect()
	end
	table.clear(activeConnections)

	-- Destroy all tracked instances (except the overlay gui itself)
	for i = #activeEffects, 1, -1 do
		local inst = activeEffects[i]
		if inst and inst ~= overlayGui and inst.Parent then
			-- Fade out particle emitters gracefully
			if inst:IsA("ParticleEmitter") then
				inst.Enabled = false
				task.delay(inst.Lifetime.Max, function()
					if inst.Parent then inst:Destroy() end
				end)
			else
				inst:Destroy()
			end
		end
		activeEffects[i] = nil
	end

	-- Clear any overlay children
	for _, child in overlayGui:GetChildren() do
		child:Destroy()
	end

	-- Remove weather parts from folder
	for _, child in WeatherFolder:GetChildren() do
		child:Destroy()
	end

	resetLightingEffects()
end

--------------------------------------------------------------------------------
-- SUNNY (default — just reset everything)
--------------------------------------------------------------------------------

local function startSunny()
	resetLightingEffects()

	local cc = createOrGetColorCorrection()
	tweenProperty(cc, {
		Saturation = 0.1,
		Brightness = 0.05,
	})
end

--------------------------------------------------------------------------------
-- RAINY
--------------------------------------------------------------------------------

local function startRainy()
	-- Atmosphere
	local atmo = createOrGetAtmosphere()
	tweenProperty(atmo, {
		Density = 0.5,
		Offset = 0.2,
		Color = Color3.fromRGB(160, 170, 180),
		Decay = Color3.fromRGB(70, 75, 85),
		Haze = 3,
	})

	local cc = createOrGetColorCorrection()
	tweenProperty(cc, {
		Saturation = -0.15,
		Brightness = -0.05,
		TintColor = Color3.fromRGB(220, 225, 235),
	})

	-- Rain emitter part (follows camera from above)
	local rainPart = createPart({
		Name = "RainEmitter",
		Size = Vector3.new(80, 1, 80),
		CFrame = CFrame.new(getCameraPosition() + Vector3.new(0, 50, 0)),
	})

	createParticleEmitter(rainPart, {
		Name = "Rain",
		Rate = RAIN_RATE,
		Lifetime = NumberRange.new(0.8, 1.2),
		Speed = NumberRange.new(60, 80),
		SpreadAngle = Vector2.new(5, 5),
		EmissionDirection = Enum.NormalId.Bottom,
		Color = ColorSequence.new(Color3.fromRGB(180, 200, 220)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(1, 0.02),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.8, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Acceleration = Vector3.new(0, -20, 0),
		RotSpeed = NumberRange.new(0),
		LightEmission = 0.1,
	})

	-- Subtle mist at ground level
	local mistPart = createPart({
		Name = "MistEmitter",
		Size = Vector3.new(100, 1, 100),
		CFrame = CFrame.new(getCameraPosition() * Vector3.new(1, 0, 1) + Vector3.new(0, 2, 0)),
	})

	createParticleEmitter(mistPart, {
		Name = "Mist",
		Rate = 15,
		Lifetime = NumberRange.new(3, 5),
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(180, 0),
		EmissionDirection = Enum.NormalId.Top,
		Color = ColorSequence.new(Color3.fromRGB(200, 210, 220)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 4),
			NumberSequenceKeypoint.new(0.5, 8),
			NumberSequenceKeypoint.new(1, 4),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.7),
			NumberSequenceKeypoint.new(0.7, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		}),
		LightEmission = 0.05,
	})

	-- Follow camera
	local conn = RunService.Heartbeat:Connect(function()
		local pos = getCameraPosition()
		rainPart.CFrame = CFrame.new(pos + Vector3.new(0, 50, 0))
		mistPart.CFrame = CFrame.new(pos * Vector3.new(1, 0, 1) + Vector3.new(0, 2, 0))
	end)
	trackConnection(conn)
end

--------------------------------------------------------------------------------
-- STORMY
--------------------------------------------------------------------------------

local function startStormy()
	-- Darker atmosphere
	local atmo = createOrGetAtmosphere()
	tweenProperty(atmo, {
		Density = 0.65,
		Offset = 0.3,
		Color = Color3.fromRGB(100, 105, 115),
		Decay = Color3.fromRGB(40, 45, 55),
		Haze = 6,
	})

	local cc = createOrGetColorCorrection()
	tweenProperty(cc, {
		Saturation = -0.25,
		Brightness = -0.12,
		Contrast = 0.1,
		TintColor = Color3.fromRGB(190, 195, 210),
	})

	-- Heavy rain
	local rainPart = createPart({
		Name = "StormRain",
		Size = Vector3.new(100, 1, 100),
		CFrame = CFrame.new(getCameraPosition() + Vector3.new(0, 60, 0)),
	})

	createParticleEmitter(rainPart, {
		Name = "HeavyRain",
		Rate = STORM_RAIN_RATE,
		Lifetime = NumberRange.new(0.6, 1.0),
		Speed = NumberRange.new(80, 110),
		SpreadAngle = Vector2.new(10, 10),
		EmissionDirection = Enum.NormalId.Bottom,
		Color = ColorSequence.new(Color3.fromRGB(150, 160, 180)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.06),
			NumberSequenceKeypoint.new(1, 0.03),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.7, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Acceleration = Vector3.new(0, -30, 0),
		LightEmission = 0.05,
	})

	-- Follow camera
	local conn = RunService.Heartbeat:Connect(function()
		rainPart.CFrame = CFrame.new(getCameraPosition() + Vector3.new(0, 60, 0))
	end)
	trackConnection(conn)

	-- Lightning flash overlay
	local flashOverlay = createOverlay("LightningFlash", Color3.new(1, 1, 1), 1)

	-- Lightning loop
	effectRunning = true
	task.spawn(function()
		while effectRunning do
			local interval = LIGHTNING_MIN_INTERVAL + math.random() * (LIGHTNING_MAX_INTERVAL - LIGHTNING_MIN_INTERVAL)
			task.wait(interval)
			if not effectRunning then break end

			-- Double flash pattern
			for strike = 1, (if math.random() > 0.6 then 2 else 1) do
				-- Flash on
				flashOverlay.BackgroundTransparency = 0.3 + math.random() * 0.3
				task.wait(0.05 + math.random() * 0.05)
				flashOverlay.BackgroundTransparency = 1
				if strike == 1 then
					task.wait(0.08 + math.random() * 0.06)
				end
			end

			-- Brief bloom spike
			local bloom = createOrGetBloom()
			bloom.Intensity = 1.5
			bloom.Threshold = 0.5
			task.wait(0.15)
			tweenProperty(bloom, {
				Intensity = 0.4,
				Threshold = 0.95,
			}, 0.5)
		end
	end)
end

--------------------------------------------------------------------------------
-- NORTHERN LIGHTS
--------------------------------------------------------------------------------

local function startNorthernLights()
	local atmo = createOrGetAtmosphere()
	tweenProperty(atmo, {
		Density = 0.35,
		Offset = 0,
		Color = Color3.fromRGB(30, 50, 80),
		Decay = Color3.fromRGB(20, 30, 50),
		Glare = 0.5,
		Haze = 1,
	})

	local cc = createOrGetColorCorrection()
	tweenProperty(cc, {
		Saturation = 0.15,
		Brightness = -0.08,
		TintColor = Color3.fromRGB(200, 220, 240),
	})

	local bloom = createOrGetBloom()
	tweenProperty(bloom, {
		Intensity = 0.8,
		Size = 40,
		Threshold = 0.8,
	})

	-- Aurora wave emitters — bands of green/purple particles high in the sky
	local auroraColors = {
		Color3.fromRGB(0, 255, 100),   -- green
		Color3.fromRGB(80, 200, 120),   -- teal-green
		Color3.fromRGB(140, 80, 220),   -- purple
		Color3.fromRGB(0, 220, 160),    -- cyan-green
		Color3.fromRGB(180, 60, 255),   -- violet
	}

	local auroraParts: { Part } = {}

	for i = 1, AURORA_WAVE_COUNT do
		local offsetX = (i - (AURORA_WAVE_COUNT + 1) / 2) * 30
		local height = 80 + math.random() * 20

		local part = createPart({
			Name = `Aurora_{i}`,
			Size = Vector3.new(60, 1, 10),
			CFrame = CFrame.new(getCameraPosition() + Vector3.new(offsetX, height, -40)),
		})
		table.insert(auroraParts, part)

		local color = auroraColors[(i - 1) % #auroraColors + 1]

		createParticleEmitter(part, {
			Name = "AuroraGlow",
			Rate = 20,
			Lifetime = NumberRange.new(2, 4),
			Speed = NumberRange.new(1, 3),
			SpreadAngle = Vector2.new(30, 10),
			EmissionDirection = Enum.NormalId.Top,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, color),
				ColorSequenceKeypoint.new(0.5, Color3.new(
					math.min(color.R + 0.2, 1),
					math.min(color.G + 0.1, 1),
					math.min(color.B + 0.2, 1)
				)),
				ColorSequenceKeypoint.new(1, color),
			}),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.2, 6 + i),
				NumberSequenceKeypoint.new(0.8, 8 + i),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.2, 0.5),
				NumberSequenceKeypoint.new(0.5, 0.3),
				NumberSequenceKeypoint.new(0.8, 0.5),
				NumberSequenceKeypoint.new(1, 1),
			}),
			LightEmission = 1,
			LightInfluence = 0,
			Orientation = Enum.ParticleOrientation.VelocityParallel,
		})
	end

	-- Animate aurora drift + follow camera
	effectRunning = true
	local elapsed = 0
	local conn = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		local camPos = getCameraPosition()

		for i, part in auroraParts do
			local offsetX = (i - (AURORA_WAVE_COUNT + 1) / 2) * 30
			local wave = math.sin(elapsed * 0.3 + i * 1.2) * 8
			local sway = math.cos(elapsed * 0.15 + i * 0.8) * 5
			local height = 80 + math.sin(elapsed * 0.2 + i) * 10
			part.CFrame = CFrame.new(
				camPos.X + offsetX + sway,
				camPos.Y + height,
				camPos.Z - 40 + wave
			)
		end
	end)
	trackConnection(conn)
end

--------------------------------------------------------------------------------
-- SOLAR ECLIPSE
--------------------------------------------------------------------------------

local function startSolarEclipse()
	local atmo = createOrGetAtmosphere()
	tweenProperty(atmo, {
		Density = 0.6,
		Offset = 0.4,
		Color = Color3.fromRGB(80, 40, 40),
		Decay = Color3.fromRGB(30, 15, 15),
		Haze = 4,
	})

	local cc = createOrGetColorCorrection()
	tweenProperty(cc, {
		Saturation = -0.3,
		Brightness = -0.15,
		Contrast = 0.2,
		TintColor = Color3.fromRGB(200, 150, 140),
	})

	local bloom = createOrGetBloom()
	tweenProperty(bloom, {
		Intensity = 0.6,
		Size = 56,
		Threshold = 0.7,
	})

	-- Dark overlay with vignette feel
	local darkOverlay = createOverlay("EclipseDark", Color3.fromRGB(10, 5, 15), 0.55)

	-- Glowing cracks — animated lines across the screen
	local crackColors = {
		Color3.fromRGB(255, 80, 20),    -- orange-red
		Color3.fromRGB(255, 40, 60),    -- crimson
		Color3.fromRGB(255, 120, 0),    -- deep orange
		Color3.fromRGB(200, 30, 80),    -- magenta-red
	}

	for i = 1, ECLIPSE_CRACK_COUNT do
		local startX = math.random() * 0.8 + 0.1
		local startY = math.random() * 0.8 + 0.1
		local angle = math.random() * 360
		local length = 0.15 + math.random() * 0.25
		local color = crackColors[(i - 1) % #crackColors + 1]

		local crack = Instance.new("Frame")
		crack.Name = `Crack_{i}`
		crack.AnchorPoint = Vector2.new(0, 0.5)
		crack.Position = UDim2.new(startX, 0, startY, 0)
		crack.Size = UDim2.new(length, 0, 0, 2)
		crack.Rotation = angle
		crack.BackgroundColor3 = color
		crack.BackgroundTransparency = 0.4
		crack.BorderSizePixel = 0
		crack.ZIndex = 2
		crack.Parent = overlayGui
		trackInstance(crack)

		-- Glow around crack (wider, more transparent)
		local glow = Instance.new("Frame")
		glow.Name = "Glow"
		glow.AnchorPoint = Vector2.new(0, 0.5)
		glow.Size = UDim2.new(1, 0, 0, 8)
		glow.Position = UDim2.new(0, 0, 0.5, 0)
		glow.BackgroundColor3 = color
		glow.BackgroundTransparency = 0.7
		glow.BorderSizePixel = 0
		glow.Parent = crack
	end

	-- Animate cracks: pulse glow and slowly drift
	effectRunning = true
	local elapsed = 0
	local conn = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		for _, child in overlayGui:GetChildren() do
			if child.Name:sub(1, 6) == "Crack_" then
				-- Pulse transparency
				local pulse = 0.3 + math.sin(elapsed * 2 + child.Rotation * 0.1) * 0.2
				child.BackgroundTransparency = pulse

				-- Slow drift
				local currentPos = child.Position
				local driftX = math.sin(elapsed * 0.5 + child.Rotation) * 0.0002
				local driftY = math.cos(elapsed * 0.4 + child.Rotation) * 0.0002
				child.Position = UDim2.new(
					currentPos.X.Scale + driftX, 0,
					currentPos.Y.Scale + driftY, 0
				)

				-- Pulse glow child
				local glowFrame = child:FindFirstChild("Glow")
				if glowFrame then
					(glowFrame :: Frame).BackgroundTransparency = 0.5 + math.sin(elapsed * 3 + child.Rotation * 0.2) * 0.3
				end
			end
		end
	end)
	trackConnection(conn)

	-- Ember particles floating upward
	local emberPart = createPart({
		Name = "EclipseEmbers",
		Size = Vector3.new(60, 1, 60),
		CFrame = CFrame.new(getCameraPosition() + Vector3.new(0, -5, 0)),
	})

	createParticleEmitter(emberPart, {
		Name = "Embers",
		Rate = 8,
		Lifetime = NumberRange.new(3, 6),
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(30, 30),
		EmissionDirection = Enum.NormalId.Top,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 100, 20)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 50, 10)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 20, 5)),
		}),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.5, 0.3),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		LightEmission = 1,
		LightInfluence = 0,
	})

	local emberConn = RunService.Heartbeat:Connect(function()
		emberPart.CFrame = CFrame.new(getCameraPosition() + Vector3.new(0, -5, 0))
	end)
	trackConnection(emberConn)
end

--------------------------------------------------------------------------------
-- METEOR SHOWER
--------------------------------------------------------------------------------

local function startMeteorShower()
	local atmo = createOrGetAtmosphere()
	tweenProperty(atmo, {
		Density = 0.25,
		Offset = 0,
		Color = Color3.fromRGB(40, 40, 70),
		Decay = Color3.fromRGB(20, 20, 40),
		Haze = 0.5,
	})

	local cc = createOrGetColorCorrection()
	tweenProperty(cc, {
		Saturation = 0.1,
		Brightness = -0.1,
		TintColor = Color3.fromRGB(210, 210, 240),
	})

	local bloom = createOrGetBloom()
	tweenProperty(bloom, {
		Intensity = 0.7,
		Size = 32,
		Threshold = 0.75,
	})

	-- Ambient star dust
	local dustPart = createPart({
		Name = "StarDust",
		Size = Vector3.new(100, 1, 100),
		CFrame = CFrame.new(getCameraPosition() + Vector3.new(0, 40, 0)),
	})

	createParticleEmitter(dustPart, {
		Name = "Dust",
		Rate = 30,
		Lifetime = NumberRange.new(2, 4),
		Speed = NumberRange.new(0.5, 2),
		SpreadAngle = Vector2.new(180, 180),
		EmissionDirection = Enum.NormalId.Bottom,
		Color = ColorSequence.new(Color3.fromRGB(200, 210, 255)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.4),
			NumberSequenceKeypoint.new(0.7, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		}),
		LightEmission = 1,
		LightInfluence = 0,
	})

	local dustConn = RunService.Heartbeat:Connect(function()
		dustPart.CFrame = CFrame.new(getCameraPosition() + Vector3.new(0, 40, 0))
	end)
	trackConnection(dustConn)

	-- Meteor streaks — spawned individually with short lifetimes
	local meteorColors = {
		Color3.fromRGB(255, 255, 220), -- warm white
		Color3.fromRGB(200, 220, 255), -- cool blue-white
		Color3.fromRGB(255, 200, 150), -- orange-white
		Color3.fromRGB(180, 200, 255), -- blue
	}

	local function spawnMeteor()
		local camPos = getCameraPosition()

		-- Random start position high and to one side
		local startOffset = Vector3.new(
			(math.random() - 0.5) * 120,
			60 + math.random() * 30,
			(math.random() - 0.5) * 120
		)
		local startPos = camPos + startOffset

		-- Direction: generally downward at an angle
		local dirAngle = math.rad(30 + math.random() * 30)
		local dirHorizontal = math.rad(math.random() * 360)
		local direction = Vector3.new(
			math.sin(dirHorizontal) * math.cos(dirAngle),
			-math.sin(dirAngle),
			math.cos(dirHorizontal) * math.cos(dirAngle)
		)

		local meteorPart = createPart({
			Name = "Meteor",
			Size = Vector3.new(0.3, 0.3, 0.3),
			CFrame = CFrame.lookAt(startPos, startPos + direction),
		})

		local color = meteorColors[math.random(1, #meteorColors)]
		local speed = 80 + math.random() * 60
		local lifetime = 0.6 + math.random() * 0.6

		-- Meteor head glow
		createParticleEmitter(meteorPart, {
			Name = "MeteorHead",
			Rate = 100,
			Lifetime = NumberRange.new(0.1, 0.2),
			Speed = NumberRange.new(0),
			Color = ColorSequence.new(color),
			Size = NumberSequence.new(0.8 + math.random() * 0.4),
			Transparency = NumberSequence.new(0),
			LightEmission = 1,
			LightInfluence = 0,
		})

		-- Meteor trail
		createParticleEmitter(meteorPart, {
			Name = "MeteorTrail",
			Rate = 200,
			Lifetime = NumberRange.new(0.3, 0.5),
			Speed = NumberRange.new(1, 3),
			SpreadAngle = Vector2.new(5, 5),
			EmissionDirection = Enum.NormalId.Back,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, color),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(
					math.floor(color.R * 255 * 0.5),
					math.floor(color.G * 255 * 0.3),
					math.floor(color.B * 255 * 0.2)
				) / Color3.new(255, 255, 255)),
			}),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.4),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(0.5, 0.4),
				NumberSequenceKeypoint.new(1, 1),
			}),
			LightEmission = 1,
			LightInfluence = 0,
			Orientation = Enum.ParticleOrientation.VelocityParallel,
		})

		-- Animate movement
		local elapsed = 0
		local moveConn: RBXScriptConnection
		moveConn = RunService.Heartbeat:Connect(function(dt: number)
			elapsed += dt
			if elapsed >= lifetime or not meteorPart.Parent then
				if moveConn then moveConn:Disconnect() end
				-- Disable emitters, let particles fade, then destroy
				for _, child in meteorPart:GetChildren() do
					if child:IsA("ParticleEmitter") then
						child.Enabled = false
					end
				end
				task.delay(0.6, function()
					if meteorPart.Parent then meteorPart:Destroy() end
				end)
				return
			end

			meteorPart.CFrame = CFrame.lookAt(
				startPos + direction * speed * elapsed,
				startPos + direction * speed * (elapsed + 0.1)
			)
		end)
		-- Don't track this connection — meteor self-cleans
	end

	-- Meteor spawn loop
	effectRunning = true
	task.spawn(function()
		while effectRunning do
			task.wait(1 / METEOR_RATE)
			if not effectRunning then break end
			spawnMeteor()
		end
	end)
end

--------------------------------------------------------------------------------
-- Weather Transition Controller
--------------------------------------------------------------------------------

local WEATHER_EFFECTS: { [string]: () -> () } = {
	sunny = startSunny,
	rainy = startRainy,
	stormy = startStormy,
	northernLights = startNorthernLights,
	solarEclipse = startSolarEclipse,
	meteorShower = startMeteorShower,
}

local function transitionToWeather(newWeather: string)
	if newWeather == activeWeather then return end

	activeWeather = newWeather
	cleanupEffects()

	-- Small delay for cleanup to settle
	task.wait(0.1)

	local startFn = WEATHER_EFFECTS[newWeather]
	if startFn then
		startFn()
	else
		-- Unknown weather, just reset to clean state
		resetLightingEffects()
	end
end

--------------------------------------------------------------------------------
-- Event Listener
--------------------------------------------------------------------------------

RE_WeatherChanged.OnClientEvent:Connect(function(newWeather: string, _previousWeather: string?, _timeRemaining: number?)
	if typeof(newWeather) ~= "string" then return end
	transitionToWeather(newWeather)
end)

--------------------------------------------------------------------------------
-- Initial State
--------------------------------------------------------------------------------

task.spawn(function()
	local RF_GetWeather = Remotes:WaitForChild("RF_GetWeather")
	local success, result = pcall(function()
		return { RF_GetWeather:InvokeServer() }
	end)
	if success and result and result[1] then
		transitionToWeather(result[1])
	end
end)
