# Arcade Game Integration Guide

Date: 2026-05-21

## Purpose
This file is for anyone making an arcade machine or arcade game that needs to work with the arcade system.

It explains:
- How the actual arcade machine fits into the system
- How the arcade machine client should communicate
- What the game is responsible for
- How player cards and save data should work
- What rules must be followed to stay compatible

## System Role
A custom arcade machine does not talk directly to the main server.

Instead, the chain is:
- actual arcade machine
- arcade machine client
- arcade backbone network
- main server

The actual arcade machine should only connect to its arcade machine client through a private wired modem network.

## Network Rules
All communication in the arcade uses physical cable only.

Required rules:
- Use wired modems only
- Do not use wireless modems
- Do not let the actual arcade machine connect directly to the wider arcade backbone
- The arcade machine and its arcade client should share their own private local cable network
- The arcade client bridges that local cabinet network to the main arcade backbone network

## Responsibilities

### Actual Arcade Machine
The actual arcade machine is the game or cabinet implementation.

It is responsible for:
- Running the game itself
- Reading its own buttons, sensors, timers, and displays
- Deciding when gameplay events happen
- Asking the arcade machine client to take credits when needed
- Asking the arcade machine client to award tickets when needed
- Loading and saving its own game-specific player progress

It is not responsible for:
- Storing trusted ticket balances
- Acting as the authority for player accounts
- Talking directly to the main server

### Arcade Machine Client
The arcade machine client sits between the cabinet and the rest of the arcade.

It is responsible for:
- Providing a stable API to the actual arcade machine
- Talking to the main server over the arcade backbone network
- Reading player cards from disk drives when needed
- Validating and forwarding ticket or credit requests
- Hiding server/network details from the game

## Compatibility Model
To stay compatible, your game should treat the arcade machine client like an API provider.

Your game should:
- Call the client when it wants to consume a credit
- Call the client when it wants to award tickets
- Ask the client for player/card information when needed
- Store only game-specific progress on the floppy disk

Your game should not:
- Change player ticket balances on its own
- Keep trusted credits on the floppy disk
- Depend on direct server access

## Core Game Flow
A typical compatible machine should work like this:

1. Wait for player card insertion or player identification.
2. Ask the arcade machine client to identify the player.
3. Load any game-specific save data from the floppy disk.
4. Wait until the player starts the game.
5. When gameplay needs a credit, ask the arcade machine client to take one.
6. If the credit request succeeds, continue gameplay.
7. When the player earns a reward, ask the arcade machine client to award tickets.
8. Save any updated game-specific progress back to the floppy disk.
9. Return to idle or attract mode.

Example flow in Lua-style pseudocode:

```lua
local player = arcadeClient.identifyPlayerFromDisk()
if not player then
	cabinet.displayMessage("Insert player card")
	return
end

local save = saveSystem.load("racing", player.cardId) or defaultSave()
cabinet.showCarStats(save)

if cabinet.waitForStartButton() then
	local ok, reason = arcadeClient.takeCredit({
		reason = "start_race",
		amount = 1,
	})

	if not ok then
		cabinet.displayMessage(reason or "Not enough credits")
		return
	end

	local result = runRace(save)

	if result.engineUpgradeBought then
		local upgradeOk = arcadeClient.takeCredit({
			reason = "engine_upgrade",
			amount = 1,
		})

		if upgradeOk then
			save.engineLevel = math.min(save.engineLevel + 1, 5)
		end
	end

	if result.tickets > 0 then
		arcadeClient.awardTickets({
			reason = "race_finish",
			amount = result.tickets,
		})
	end

	saveSystem.store("racing", player.cardId, save)
end
```

## Credit Rules
The actual game decides when a credit should be spent.

Examples:
- One credit to start a run
- One credit per continue
- One credit per upgrade purchase
- One credit per extra life

These costs should be configurable inside the game, not inside the arcade machine client.

Recommended config values:
- creditCostStart
- creditCostContinue
- creditCostUpgrade
- creditCostExtraLife

Example config:

```lua
local config = {
	creditCostStart = 1,
	creditCostContinue = 2,
	creditCostUpgrade = 1,
	creditCostExtraLife = 1,
}
```

## Ticket Award Rules
The actual game also decides when tickets should be awarded and how many to award.

Examples:
- Fixed reward for finishing a game
- Score-based reward
- Reward per action
- Bonus reward for combos or milestones

These values should also be configurable inside the game.

Recommended config values:
- awardMode
- awardPerWin
- awardPerMilestone
- awardByScoreTier
- maxAwardPerRound

Example config:

```lua
local awards = {
	awardMode = "score_tier",
	awardPerWin = 25,
	awardPerMilestone = 5,
	awardByScoreTier = {
		{ minScore = 0, tickets = 0 },
		{ minScore = 100, tickets = 5 },
		{ minScore = 250, tickets = 10 },
		{ minScore = 500, tickets = 20 },
	},
	maxAwardPerRound = 30,
}
```

The game should request ticket awards through the arcade machine client.
The game should not edit balances itself.

## Cabinet API Design
The arcade machine should expose or use a small, predictable API surface.

Recommended actions:
- init
- reset
- start_game
- stop_game
- attract_mode_on
- attract_mode_off
- display_message
- show_score
- show_tickets

Recommended event types:
- start_pressed
- input_changed
- round_started
- round_ended
- score_updated
- error_state

The point is not that every cabinet must look identical.
The point is that each cabinet should map its own hardware into a standard set of actions and events so the arcade client can support it cleanly.

Example local API shape:

```lua
local cabinetApi = {}

function cabinetApi.init()
	return true
end

function cabinetApi.getState()
	return {
		mode = "idle",
		score = 0,
		ready = true,
	}
end

function cabinetApi.displayMessage(message)
	monitor.clear()
	monitor.setCursorPos(1, 1)
	monitor.write(message)
end

function cabinetApi.showScore(score)
	cabinetApi.displayMessage("Score: " .. tostring(score))
end

function cabinetApi.reset()
	redstone.setOutput("back", false)
end

return cabinetApi
```

Example event payload:

```lua
{
	type = "score_updated",
	gameId = "racing",
	cabinetId = "cabinet-racing-01",
	score = 420,
	lap = 3,
	timestamp = os.epoch("utc"),
}
```

Example credit request:

```lua
{
	type = "game.credit.take",
	requestId = "req-1001",
	gameId = "racing",
	cabinetId = "cabinet-racing-01",
	payload = {
		amount = 1,
		reason = "engine_upgrade",
	},
}
```

Example ticket request:

```lua
{
	type = "game.ticket.award",
	requestId = "req-1002",
	gameId = "racing",
	cabinetId = "cabinet-racing-01",
	payload = {
		amount = 15,
		reason = "race_finish",
		score = 420,
	},
}
```

Example success response:

```lua
{
	ok = true,
	requestId = "req-1002",
	data = {
		newBalance = 182,
		awarded = 15,
	},
}
```

Example failure response:

```lua
{
	ok = false,
	requestId = "req-1001",
	error = "INSUFFICIENT_CREDITS",
}
```

## Multi-Computer Cabinets
Some arcade machines may use more than one ComputerCraft computer.

Recommended structure:
- One cabinet host computer runs the main game logic
- Optional helper computers run scoreboards, displays, or sub-games
- Those helper computers stay on the cabinet's private local network
- The arcade machine client is the only bridge out to the main arcade backbone

This keeps cabinet internals flexible without exposing the rest of the arcade network.

## Player Cards
Players use floppy disks as physical cards.

The card should include an identity file such as:
- /arcade_card.txt

Example contents:
- cardId=AC-8F23-19B7
- version=1

Example file contents:

```text
cardId=AC-8F23-19B7
version=1
issuedAt=1779326400
```

Important rule:
- The floppy disk may identify the player
- The floppy disk must not be trusted for ticket balance authority

The real ticket balance comes from the server through the arcade machine client.

## Game Save Data on Cards
Games are allowed to store their own save data on the floppy disk.

This is good for things like:
- Car upgrades
- Character unlocks
- Loadouts
- Personal progress
- High scores specific to that player

Recommended layout:
- /arcade_card.txt
- /saves/racing.txt
- /saves/shooter.txt
- /saves/your_game_id.txt

Recommended save rules:
- Each game uses its own file
- Each game only reads and writes its own file
- Missing save files should create default data
- Broken save files should be ignored and recreated safely

Example save file:
- profileVersion=1
- engineLevel=3
- tireLevel=2
- armorLevel=1
- paint=red

Example file contents:

```text
profileVersion=1
engineLevel=3
tireLevel=2
armorLevel=1
paint=red
lastPlayedAt=1779326400
```

## Save Data Safety
Treat floppy-disk save data as convenience data, not trusted economy data.

Required safeguards:
- Validate all loaded values
- Clamp upgrade levels to allowed ranges
- Ignore malformed values
- Rebuild defaults if the file is corrupted
- Never trust the floppy disk for ticket balances or account authority

Optional safeguards:
- Add a checksum line
- Add a signature line
- Later mirror important progression data to the server

## Suggested Game Config
A compatible game should probably have a config table or file with values like:

- gameId
- displayName
- creditCostStart
- creditCostContinue
- allowContinues
- awardMode
- awardPerWin
- awardByScoreTier
- maxAwardPerRound
- saveFilePath
- attractModeEnabled

Example full config:

```lua
local gameConfig = {
	gameId = "racing",
	displayName = "Turbo Track",
	creditCostStart = 1,
	creditCostContinue = 2,
	allowContinues = true,
	awardMode = "score_tier",
	awardPerWin = 25,
	awardByScoreTier = {
		{ minScore = 100, tickets = 5 },
		{ minScore = 250, tickets = 10 },
		{ minScore = 500, tickets = 20 },
	},
	maxAwardPerRound = 30,
	saveFilePath = "/saves/racing.txt",
	attractModeEnabled = true,
}
```

## Recommended Error Handling
Your game should handle these cases cleanly:
- No player card inserted
- Card file missing or broken
- Save data missing or broken
- Credit request denied
- Ticket award request failed
- Arcade machine client offline
- Server unreachable through the arcade machine client

Recommended behavior:
- Show a clear player-facing message
- Do not spend local state if the client denies the request
- Return to idle safely when a fatal error happens

## Integration Checklist
A custom game is compatible if it does all of the following:
- Uses wired modems only
- Connects only to its arcade machine client on the local cabinet network
- Never talks directly to the main server
- Lets the game decide when to consume credits
- Lets the game decide when to award tickets
- Requests those operations through the arcade machine client
- Stores only game-specific save data on the floppy disk
- Never treats disk data as ticket authority
- Handles missing cards, save errors, and offline network states safely

## Example Scenario
Example: racing game with persistent upgrades

1. Player inserts floppy disk.
2. Game reads /arcade_card.txt and asks the arcade machine client to identify the player.
3. Game reads /saves/racing.txt.
4. Game restores the player's car upgrades.
5. Player buys an engine upgrade.
6. Game asks the arcade machine client to take one credit.
7. If approved, the game increases engineLevel and writes the new save file.
8. Player wins a race.
9. Game calculates the reward and asks the arcade machine client to award tickets.
10. Game returns to idle and keeps the upgraded car saved for next time.

Example saved state after the session:

```text
profileVersion=1
engineLevel=4
tireLevel=2
armorLevel=1
paint=red
lastPlayedAt=1779326700
```

## Bottom Line
If you are building a custom arcade machine, keep the machine focused on gameplay.
Let the arcade machine client handle the rest of the arcade system.

The cabinet should own:
- gameplay
- local hardware
- save data format
- credit and reward timing

The arcade machine client should own:
- server communication
- card identification flow
- ticket and credit requests
- network bridging
