# Bloom Island — Roblox Game Project

## Language
This project uses **Luau** (not Lua 5.1, not JavaScript, not TypeScript).
Always write Luau code with proper type annotations where helpful.
File extensions: `.server.luau`, `.client.luau`, `.luau` (shared modules).

## Project Structure (Rojo)
```
bloom-island/
├── default.project.json          # Rojo project config
├── CLAUDE.md                     # This file
├── src/
│   ├── server/                   # ServerScriptService
│   │   ├── PlantSystem.server.luau
│   │   ├── MutationEngine.server.luau
│   │   ├── WeatherSystem.server.luau
│   │   ├── TradingSystem.server.luau
│   │   ├── CreatureSystem.server.luau
│   │   ├── DataManager.server.luau
│   │   └── MonetizationHandler.server.luau
│   ├── client/                   # StarterPlayerScripts
│   │   ├── GardenUI.client.luau
│   │   ├── WeatherEffects.client.luau
│   │   ├── NotificationSystem.client.luau
│   │   ├── TradingUI.client.luau
│   │   └── CameraController.client.luau
│   ├── shared/                   # ReplicatedStorage
│   │   ├── Config/
│   │   │   ├── PlantData.luau    # All plant definitions
│   │   │   ├── MutationData.luau # Mutation tiers and odds
│   │   │   ├── CreatureData.luau # Creature definitions
│   │   │   └── GameConfig.luau   # Global settings
│   │   ├── Types.luau            # Shared type definitions
│   │   └── Utils.luau            # Shared utility functions
│   └── starter/                  # StarterGui
│       └── MainGui.client.luau
├── assets/                       # 3D models (.rbxm), images
└── localization/                 # CSV files for translations
```

## Roblox Architecture Rules

### Client-Server Boundary
- **NEVER trust the client.** All game logic (growth calculations, mutation rolls, coin changes, trades) MUST run on the server.
- Client scripts handle: UI rendering, visual effects, camera, input, animations.
- Server scripts handle: data persistence, game logic, economy, validation.
- Communication: use RemoteEvents and RemoteFunctions in ReplicatedStorage.

### Naming Conventions
- RemoteEvents: `RE_PlantSeed`, `RE_HarvestPlant`, `RE_RequestTrade`
- RemoteFunctions: `RF_GetPlayerData`, `RF_GetTradeValue`
- Modules: PascalCase (`PlantData`, `MutationEngine`)
- Variables: camelCase (`localPlayer`, `growthRate`)
- Constants: UPPER_SNAKE_CASE (`MAX_PLOTS`, `BASE_GROW_TIME`)

### Services (use GetService, never index directly)
```luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
```

### DataStore Pattern
Always use UpdateAsync (never SetAsync) with retry logic:
```luau
local function savePlayerData(player: Player, data: PlayerData)
    local key = "Player_" .. player.UserId
    local success, err
    for attempt = 1, 3 do
        success, err = pcall(function()
            DataStore:UpdateAsync(key, function(oldData)
                return data
            end)
        end)
        if success then break end
        task.wait(1)
    end
    if not success then
        warn("Failed to save data for", player.Name, err)
    end
end
```

### RemoteEvent Pattern
Always validate on server, never trust client arguments:
```luau
-- Server
RE_PlantSeed.OnServerEvent:Connect(function(player, plotIndex, seedId)
    -- Validate types
    if typeof(plotIndex) ~= "number" then return end
    if typeof(seedId) ~= "string" then return end
    
    -- Validate ranges
    if plotIndex < 1 or plotIndex > playerData.maxPlots then return end
    
    -- Validate ownership
    local seedData = PlantData[seedId]
    if not seedData then return end
    if playerData.coins < seedData.cost then return end
    
    -- Execute logic server-side
    playerData.coins -= seedData.cost
    playerData.plots[plotIndex] = {
        seedId = seedId,
        plantedAt = os.time(),
        mutation = nil,
    }
end)
```

## Game-Specific Context

### Bloom Island is a Social Idle Garden Game
- Players plant seeds → seeds grow over time → harvest for coins → buy upgrades
- Mutation system: when plants finish growing, RNG roll determines if mutation occurs
- Weather system: synchronized across all servers, affects growth speed and mutation chance
- Creatures: hatchable pets that provide passive bonuses
- Trading: player-to-player economy for rare mutations and creatures
- Garden visiting: players can visit and rate each other's gardens

### Economy Balance Guidelines
- Early game: player should earn enough in 5 min to buy next seed tier
- Mid game: progression slows, upgrades take 15-30 min of play
- Late game: rare items take days of play OR lucky mutation rolls
- Coin sinks: creature evolution, garden decorations, seasonal pass
- Never let players generate coins faster than the economy can absorb

### Mutation Odds (server-side only, never expose exact odds to client)
- Golden: base 10% (modified by weather + upgrades)
- Rainbow: base 2%
- Cosmic: base 0.2%
- Celestial: base 0.02%
- Mythical: base 0.002%
- ???: base 0.0001% (hidden tier, no UI hint)

## Code Style
- Use `local` for everything
- Use type annotations for function parameters
- Return early for validation (guard clauses)
- Group related functionality into ModuleScripts
- Use task.wait() instead of wait() (deprecated)
- Use task.spawn() instead of spawn() (deprecated)
- Use task.delay() instead of delay() (deprecated)
- String interpolation: use backtick strings `` `Hello {player.Name}` ``
- Never use string.format when backtick interpolation works

## Commands
- `rojo serve` — Start live sync with Roblox Studio
- `rojo build -o bloom-island.rbxl` — Build place file
- `rojo sourcemap default.project.json -o sourcemap.json` — Generate sourcemap

## Testing
- Test in Roblox Studio with Play Solo and local server (2 players)
- Check Output window for warnings and errors
- Use print() for debug, warn() for issues, error() for critical failures
- Remove debug prints before committing

## Localization
- All player-facing strings go through the shared Localization module
- Never hardcode English strings in UI code
- Use key format: `UI.Button.Plant`, `Game.Weather.Rain`, `Item.Seed.Daisy`
- CSV files in /localization/ are imported to Roblox LocalizationTable
