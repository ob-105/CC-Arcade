# ComputerCraft Arcade System Plan

Date: 2026-05-21

## Goal
Build a three-machine arcade system in Minecraft using ComputerCraft:

1. Front desk computer for staff-only player management.
2. Standalone ticket and balance checker for players.
3. Arcade game computers that spend and award tickets.

## High-Level Architecture
Use one central authority server for all balance changes.

1. Central Server (authoritative data and logging)
2. Front Desk Client (admin tools)
3. Checker Client (read-only kiosk)
4. Game Clients (arcade machine controllers)

Recommended setup:
- Use rednet only over wired modems.
- All arcade communication should use physical wires only.
- Computers do not need to be physically near each other.
- Each cabinet and its arcade client should share a private local cable network.
- That local network connects to the wider arcade cable network through the arcade client.
- The wider arcade network connects to all other clients and the main server.
- Only the server can write player balances.
- Other machines send requests and receive responses.

## Central Server UI
The main server should have a real user interface instead of only running in the background.

Server UI goals:
- Show live player balances
- Show connected arcade clients and cabinets
- Show recent transactions and ticket changes
- Show machine status, errors, and offline warnings
- Allow staff to search players and inspect card links
- Allow admin-only adjustments and maintenance actions

Suggested UI layout:
- Top bar: server status, network status, and staff login state
- Left panel: player search, card lookup, and machine list
- Center panel: selected player or machine details
- Right panel: live logs, recent transactions, and alerts
- Bottom bar: quick actions such as add tickets, rename player, or reconnect machine

The server UI should be usable from the front desk or any trusted staff terminal on the wired arcade network.

Example UI sections:

```text
+----------------------------------------------------------------------------------+
| Arcade Server | Online | Players: 42 | Machines: 12 | Alerts: 1                 |
+----------------------------------------------------------------------------------+
| Players                     | Details                          | Logs            |
| Player A 182 tickets        | Player: Player A                | 12:01 award +10 |
| Alex      45 tickets        | Card: AC-8F23-19B7              | 12:02 spend -1  |
| Sam      301 tickets        | Last machine: racing-01         | 12:02 online    |
| ...                         | Recent transactions shown here  | 12:03 error     |
+----------------------------------------------------------------------------------+
| F1 Search | F2 Add Tickets | F3 Rename | F4 Machines | F5 Cards | F6 Logs        |
+----------------------------------------------------------------------------------+
```

## Machine Responsibilities

### 1) Front Desk Computer (Admin Console)
Staff-only operations:
- Create player profile
- Rename player
- Add tickets
- Remove tickets (with reason)
- View recent transactions

Safety controls:
- Staff login/password
- Confirmation prompt before negative adjustments

### 2) Balance Checker Computer (Read-Only Kiosk)
Player operations:
- Lookup player by card/name/id
- Show ticket balance
- Show last N transactions (for example last 5)

Restrictions:
- No write actions
- No admin actions

### 3) Arcade Machine Computers (Game Clients)
Game operations:
- Identify active player (card or id)
- Optionally charge entry cost
- Award tickets based on score/outcome
- Show success or failure messages

Restrictions:
- No direct file edits to balances
- All spend/award requests must be validated by server

### 4) Actual Arcade Machines (Cabinets / Devices)
These are the physical games themselves, which may vary a lot from machine to machine.

Examples:
- One monitor cabinet with a single input panel
- Multi-panel cabinet with multiple buttons and sensors
- Cabinet that uses more than one ComputerCraft computer
- Cabinet with custom devices like levers, lights, timers, or score counters

Recommended approach:
- Treat each cabinet as a hardware profile.
- The cabinet exposes a small API that the arcade machine client can call.
- The arcade machine client decides when to request a credit spend or ticket award.
- The actual game logic controls when to trigger those requests.

Cabinet responsibilities:
- Expose actions such as start, reset, read input state, and report score events
- Report status such as ready, busy, error, and attract mode
- Expose hardware differences through a small local interface

Arcade machine computer responsibilities:
- Provide an API for the game client to read cabinet state and send cabinet commands
- Forward cabinet events to the game client in a normalized format
- Let the game client decide when to consume a credit
- Let the game client request ticket awards based on game actions
- Communicate standardized requests to the central server when needed

This lets the same server and ticket logic work across many cabinet styles.

## Data Model

### Player Record
- playerId: string (unique)
- displayName: string
- tickets: integer
- createdAt: epoch time
- updatedAt: epoch time
- pinHash: optional string
- cardId: optional string

### Transaction Record
- txId: string
- playerId: string
- type: load | spend | award | adjust | rename | link_card
- amount: integer (0 for rename/link)
- balanceAfter: integer
- sourceMachineId: string
- sourceRole: admin | kiosk | game
- note: optional string
- timestamp: epoch time

## Message Protocol (Rednet)
All requests should include:
- requestId
- machineId
- role
- token (shared secret)
- timestamp
- payload

Suggested message types:
- auth.login
- player.lookup
- player.create
- player.rename
- player.linkCard
- balance.get
- tickets.add
- tickets.spend
- tickets.award
- tx.listRecent
- ping

For cabinet and machine communication, also support:
- cabinet.register
- cabinet.status
- cabinet.input
- cabinet.command
- cabinet.config
- cabinet.ping
- game.credit.take
- game.ticket.award
- game.state.update

Response shape:
- ok: boolean
- requestId
- error: optional string
- data: optional table

Example request:

```lua
{
   requestId = "req-2001",
   machineId = "game-racing-01",
   role = "game",
   token = "shared-secret",
   timestamp = os.epoch("utc"),
   type = "tickets.award",
   payload = {
      playerId = "player-a",
      amount = 15,
      note = "race_finish",
   },
}
```

Example response:

```lua
{
   ok = true,
   requestId = "req-2001",
   data = {
      balanceAfter = 182,
      transactionId = "tx-9001",
   },
}
```

## Cabinet Communication Layer
Not every arcade machine will use the same hardware, so each cabinet should have its own adapter definition.

### Physical Wiring Rule
Every cabinet, arcade machine client, and support computer should connect through wired modem lines only.

This means:
- No wireless modems
- No radio-based communication
- Long cable runs are fine if the cabinet is far from the arcade machine computer
- The cabinet can be in a different physical location as long as the wired modem network reaches it

### Network Topology
Use two cable layers:

1. Local cabinet network
- Connects the actual arcade machine to its arcade client
- Does not connect directly to the rest of the arcade
- Carries only cabinet-specific events and commands

2. Arcade backbone network
- Connects all arcade clients and the main server
- Carries player data, ticket operations, and machine coordination
- The arcade client acts as the bridge between the local cabinet network and the arcade backbone network

Example topology:

```text
[Racing Cabinet]----wired modem----[Racing Arcade Client]----wired backbone----[Main Server]
                                              |
                                              +----------------wired backbone----[Front Desk]
                                              |
                                              +----------------wired backbone----[Balance Checker]
                                              |
                                              +----------------wired backbone----[Shooter Client]
```

### Cabinet Profile
Each cabinet should have a small config file that describes:
- cabinetId: unique string
- cabinetType: example game type or layout name
- inputDevices: list of attached peripherals or neighbor computers
- outputDevices: list of displays, speakers, lights, or motors
- scoreMode: how the cabinet calculates points
- ticketMode: how points map to tickets

### Standard Cabinet Events
All cabinet types should convert their local hardware into a common set of events:
- coin_inserted
- start_pressed
- player_joined
- input_changed
- round_started
- round_ended
- score_updated
- error_state

### Game Client Control Layer
The actual game client should own the gameplay rules and decide when to talk to the arcade machine client API.

Configurable inside the game client:
- creditCost: how many credits it takes to start or continue
- awardTable: how many tickets to award for each action or score tier
- awardMode: fixed, score-based, event-based, or combo-based
- maxAwardPerRound: optional cap on tickets per play session

Game client responsibilities:
- Decide when to request a credit from the cabinet or arcade machine client
- Decide when an action should award tickets
- Decide how many tickets to award for that action
- Send the award request through the arcade machine API

This keeps the cabinet simple while making the game logic flexible.

### Standard Cabinet Commands
The arcade machine computer should be able to send these commands back to the cabinet:
- init
- attract_mode_on
- attract_mode_off
- start_game
- stop_game
- reset
- display_message
- show_score
- show_tickets

### Multi-Computer Cabinets
Some arcade machines may need more than one ComputerCraft computer.

Suggested pattern:
- One local controller computer is the cabinet host.
- Extra computers handle sub-systems such as scoreboards, minigames, or input panels.
- The cabinet host talks to the main arcade machine computer.
- The main arcade machine computer talks to the central server.

This keeps the internal cabinet wiring flexible while preserving one shared game API.

## Permissions Model
- admin role: full create/read/update operations
- kiosk role: lookup + read-only balance/history
- game role: spend/award only for current session

Server should enforce role checks, never trust client UI role alone.

## Player Cards Using Floppy Disks
Yes, you can use floppy disks as physical player cards.

### How it works
Each player gets one floppy disk that stores a card file with a unique card id.
A disk drive connected to front desk/checker/game machines reads the card id.
The server maps cardId -> playerId.

### Recommended card file format
Disk label: "Arcade Card"
File on disk (for example /arcade_card.txt):

- cardId=AC-8F23-19B7
- version=1

Only store card identity on disk, not ticket balance.
Balance always comes from the server.

### Optional Player Save Data on Disk
The floppy disk can also store game-specific player progress in separate files.

This is useful for things like:
- Racing game car upgrades
- Loadouts or unlocks
- Personal bests
- Campaign or level progress

Recommended rule:
- Keep identity in one file
- Keep each game's saved data in its own separate file
- Never store ticket balance or trusted credit balance on the disk

Example disk layout:
- /arcade_card.txt
- /saves/racing.txt
- /saves/shooter.txt

Example racing save file:
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

Recommended behavior:
- When the player inserts their disk, the game client reads the matching save file for that game
- If the file exists, the game restores the player's upgrades or progress
- If the file does not exist, the game creates a new default save
- When the player earns or buys an upgrade, the game writes the updated save file back to disk

This gives the player persistent progress across visits without touching the main ticket system.

### Save Data Ownership
The actual game should own the format of its own save file.

That means:
- The racing game decides what upgrade fields exist
- Another game can use a completely different save structure
- Each game should only read and write its own namespaced save file

This keeps different arcade machines from overwriting each other's data.

### Save Data Safety Rules
To avoid abuse or broken cards:
- Treat disk save data as player-owned convenience data, not trusted economy data
- Validate every saved value before using it
- Clamp upgrades to allowed ranges
- Ignore malformed save files and recreate defaults if necessary
- Keep all tickets, credits, and account authority on the server or approved game logic

Optional hardening:
- Add a checksum or signature line to each save file
- Mirror important progression data to the server later if needed

### Why this is good
- Physical card experience for players
- Easy replacement: issue new disk, relink cardId
- Secure enough for arcade use when combined with server checks
- Lets players keep game progress between sessions

### Card lifecycle
1. Issue card:
   - Staff inserts blank disk at front desk
   - System generates cardId and writes card file
   - Optional: set disk label to player name + short id
2. Link card:
   - Front desk links cardId to playerId on server
3. Use card:
   - Checker/game reads cardId from disk
   - Sends card lookup to server
   - Game optionally loads per-game save data from disk
4. Replace lost card:
   - Mark old cardId as inactive
   - Create new cardId and relink player

### Anti-abuse tips
- Keep shared token private on trusted machines only
- Add allowlist of machine IDs on server
- Optionally sign card data with hash:
  - cardId + secret -> signature
  - verify signature when reading disk
- Rate limit failed lookups from same machine

## Failure Handling
- If server offline, checker/game shows "Arcade system offline" and blocks writes.
- Server saves periodic backups of player database and transaction log.
- On startup, server validates data files and creates missing defaults.

## Suggested Build Order (MVP)
1. Build server with file storage and transaction logging.
2. Build front desk admin UI (create/rename/add/remove/check).
3. Add floppy card issue + link flow at front desk.
4. Build read-only checker kiosk with card reader support.
5. Build one game client with spend/award flow.
6. Add security hardening (allowlist, token checks, optional signature).
7. Add backups, restore command, and startup self-checks.

## File Layout Suggestion
- /server/main.lua
- /server/db/players.db
- /server/db/transactions.db
- /shared/protocol.lua
- /shared/security.lua
- /frontdesk/main.lua
- /kiosk/main.lua
- /game/main.lua

## Notes for Later
- Add optional PIN check for high-value transactions.
- Add leaderboard and prize redemption terminal.
- Add staff audit view filtered by machine and date.
