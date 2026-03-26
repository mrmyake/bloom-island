-- AnnouncementSystem: Broadcasts server-wide and cross-server announcements
-- via MessagingService. Hooks into rare mutation discoveries (Cosmic+).
-- Fires RE_ServerAnnouncement to all clients for golden banner display.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MessagingService = game:GetService("MessagingService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlantData = require(Shared.Config.PlantData)
local MutationData = require(Shared.Config.MutationData)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local ANNOUNCEMENT_TOPIC = "BloomIsland_Announcements"

-- Mutations at this rarity or above trigger a server-wide broadcast
local BROADCAST_MUTATIONS: { [string]: boolean } = {
	cosmic = true,
	celestial = true,
	mythical = true,
	secret = true,
}

-- Rarity → banner accent color (sent to clients)
local RARITY_COLORS: { [string]: { r: number, g: number, b: number } } = {
	cosmic = { r = 155, g = 89, b = 182 },
	celestial = { r = 255, g = 69, b = 0 },
	mythical = { r = 0, g = 255, b = 255 },
	secret = { r = 255, g = 255, b = 255 },
}

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

local function getOrCreateBindable(className: string, name: string): Instance
	local bindable = ServerStorage:FindFirstChild(name)
	if not bindable then
		bindable = Instance.new(className)
		bindable.Name = name
		bindable.Parent = ServerStorage
	end
	return bindable
end

-- Server → Client: golden banner announcement
local RE_ServerAnnouncement = getOrCreateRemote("RemoteEvent", "RE_ServerAnnouncement")

-- BindableEvent: other server scripts can trigger announcements
local BE_Announce = getOrCreateBindable("BindableEvent", "BE_Announce") :: BindableEvent

-- BindableEvent: mutation discovery hook (fired by PlantSystem)
local BE_MutationDiscovery = getOrCreateBindable("BindableEvent", "BE_MutationDiscovery") :: BindableEvent

--------------------------------------------------------------------------------
-- Broadcast to All Clients on This Server
--------------------------------------------------------------------------------

local function broadcastLocal(announcement)
	RE_ServerAnnouncement:FireAllClients(announcement)
end

--------------------------------------------------------------------------------
-- Cross-Server Broadcast via MessagingService
--------------------------------------------------------------------------------

local function broadcastGlobal(announcement)
	-- Send to this server first
	broadcastLocal(announcement)

	-- Then to all other servers
	pcall(function()
		MessagingService:PublishAsync(ANNOUNCEMENT_TOPIC, announcement)
	end)
end

-- Listen for announcements from other servers
pcall(function()
	MessagingService:SubscribeAsync(ANNOUNCEMENT_TOPIC, function(message)
		local announcement = message.Data
		if not announcement then return end
		broadcastLocal(announcement)
	end)
end)

--------------------------------------------------------------------------------
-- Mutation Discovery Hook
--------------------------------------------------------------------------------

BE_MutationDiscovery.Event:Connect(function(playerName: string, seedId: string, mutationId: string)
	if not BROADCAST_MUTATIONS[mutationId] then return end

	local mutData = MutationData[mutationId]
	local plantInfo = PlantData[seedId]
	if not mutData then return end

	local mutationName = mutData.name
	local plantName = if plantInfo then plantInfo.name else seedId
	local rarity = mutData.rarity
	local accentColor = RARITY_COLORS[mutationId]

	broadcastGlobal({
		type = "mutation_discovery",
		title = `{rarity} Discovery!`,
		message = `{playerName} just discovered a {mutationName} {plantName}!`,
		accentColor = accentColor,
		mutationId = mutationId,
		rarity = rarity,
		duration = 5,
	})
end)

--------------------------------------------------------------------------------
-- Generic Announcement Hook (for admin/event messages)
--------------------------------------------------------------------------------

BE_Announce.Event:Connect(function(title: string, message: string, accentColor, duration: number?)
	broadcastGlobal({
		type = "generic",
		title = title,
		message = message,
		accentColor = accentColor,
		duration = duration or 5,
	})
end)
