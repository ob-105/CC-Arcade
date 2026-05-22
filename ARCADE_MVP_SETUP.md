# ComputerCraft Arcade MVP Setup

Date: 2026-05-21

This setup gives you a working minimum arcade system with:
- Authoritative ticket server
- Front desk admin terminal
- Player balance checker kiosk
- One demo game cabinet client
- One-click role installer that writes startup
- Boot-time auto-updating from GitHub

Card ownership model:
- Credits and tickets are owned by the card account (cardId), not by a separate linked user identity.
- If a card is lost, its balances stay with that card; anyone who inserts that card can use them.

Current testing mode:
- Ticket economy is temporarily disabled by default for easier bring-up.
- Ticket spend/award requests are accepted but bypassed while disabled.
- Credits remain active and are used for gameplay start/upgrade costs.

## Project Files

- `/shared/protocol.lua`
- `/shared/security.lua`
- `/shared/net.lua`
- `/shared/updater.lua`
- `/server/main.lua`
- `/frontdesk/main.lua`
- `/kiosk/main.lua`
- `/game/main.lua`
- `/cabinet_test/main.lua`
- `/install.lua`

## Quick Install (Recommended)

On each ComputerCraft computer:

1. Place this project folder on the computer (or disk mount).
2. Run installer:

```lua
shell.run("/install.lua")
```

3. Pick machine role:
  - Central Server
  - Front Desk Admin
  - Balance Checker Kiosk
  - Game Cabinet Client
  - Cabinet Test Machine

The installer will:
- Copy only required files for that role
- Preserve or create `/arcade_token.txt`
- Write `/arcade_role.txt` for role metadata
- Write `/startup` to auto-update from GitHub, then run that machine's main program
- Offer reboot so startup immediately applies

If the installer is run from a temporary HTTP path (for example `wget run ...`), it now auto-falls back to downloading required files directly from GitHub.

This startup behavior keeps machines persistent across chunk unload/reload, because ComputerCraft reruns startup on boot.

## Auto Update Behavior

On every boot, startup calls `/shared/updater.lua` first.

Updater behavior:
- Reads `/arcade_role.txt`
- Downloads latest shared + role files from GitHub `main`
- Replaces local installed code
- Continues to machine program even if update fails

Important:
- ComputerCraft HTTP API must be enabled in server config for updates to work.
- Token file `/arcade_token.txt` is not overwritten by updater.

## Troubleshooting Installer Source Errors

If you saw warnings like `Missing source: rom/programs/http/...`, that means installer was launched from an HTTP temp path without local project files next to it.

Use either approach:
- Run installer from a full local project copy
- Or keep using `wget run` with HTTP enabled, and installer will fetch needed files from GitHub automatically

## Troubleshooting Startup Errors

If boot shows:
- `[startup] updater not available`
- `No such program`

Then startup was written before required files were installed.

Fix on that machine:
1. Run installer again using latest version:

```lua
shell.run("/install.lua")
```

2. Pick the role again and allow overwrite.
3. Reboot.

Latest startup now includes bootstrap logic that downloads missing updater and role program files automatically when possible.

## 1) Wire the Network

Use wired modems only.

Recommended wiring:
- Server computer on wired backbone
- Front desk computer on wired backbone
- Kiosk computer on wired backbone
- Game client computer on wired backbone
- Optional cabinet helper computers on game client's private local wired segment

No wireless modems.

## 2) Copy Files to Each Computer

Every machine needs the `/shared` folder and its own role folder.

Server machine:
- `/shared/*`
- `/server/main.lua`

Front desk machine:
- `/shared/*`
- `/frontdesk/main.lua`

Kiosk machine:
- `/shared/*`
- `/kiosk/main.lua`

Game machine:
- `/shared/*`
- `/game/main.lua`

Cabinet test machine:
- `/shared/*`
- `/cabinet_test/main.lua`

## 3) Shared Token

On every machine, create:
- `/arcade_token.txt`

Use the same single-line token string on all machines.

Example:

```text
arcade-secret-001
```

## 4) Start Order

1. Start server first:

```lua
shell.run("/server/main.lua")
```

2. Start front desk:

```lua
shell.run("/frontdesk/main.lua")
```

3. Start kiosk:

```lua
shell.run("/kiosk/main.lua")
```

4. Start game:

```lua
shell.run("/game/main.lua")
```

Clients auto-discover server using `ping`.

## 5) Front Desk First-Time Flow

At the front desk terminal:

- Use mouse clicks on the dashboard UI buttons (keyboard shortcuts still work).

1. Create player
2. Insert blank floppy disk
3. Issue new card on disk
4. Press Card to register/use that card account
5. Load credits to selected player or directly from inserted card

The card file is written to:
- `/disk/arcade_card.txt`

## 6) Kiosk Flow

At kiosk terminal:

- Insert player card disk and choose read card
- Or lookup by playerId
- View credits, ticket balance, and last transactions

## 7) Game Flow

At game terminal:

- Insert linked player card disk
- Start round when cabinet sends a start event over cabinet modem network
- Game spends credits for start and optional upgrades
- Game awards tickets by score tier (awards are bypassed while ticket mode is disabled)
- Save data is kept on card at:
  - `/top-drive-mount/saves/demo_racer.txt`

No operator interaction is required during normal play. This allows the arcade client computer to stay underground/inaccessible during operation.

Default physical side config in game client:
- Backbone network wired modem: `bottom`
- Cabinet local network wired modem: `back`
- Card disk drive: `top`

Cabinet start messages accepted on the back modem channel:
- `cabinet.start_pressed`
- `start_pressed`

## 8) Server Data Files

Server writes:
- `/server/db/players.db`
- `/server/db/transactions.db`
- `/server/db/allowlist.db` (optional, empty means allow all)

## 9) Notes

- Credits and tickets are authoritative on server only.
- Card floppy is identity + game-specific save storage.
- If you later add cabinet adapters, keep machine-to-server requests routed through the game client API.

## 10) Cabinet Test Game (Actual Arcade Machine)

Use this when validating the local cabinet network before building a full cabinet game.

Script:
- `/cabinet_test/main.lua`

What it does:
- Connects to the cabinet local wired modem network
- Sends `cabinet.start_pressed` events to arcade client
- Displays client events (`client.player_ready`, `client.round_starting`, `client.round_complete`, etc.)
- Supports keyboard and redstone start trigger

Run on the actual cabinet machine:

```lua
shell.run("/cabinet_test/main.lua")
```

Default test script sides/channels:
- Modem side: `back`
- Start button redstone side: `front`
- Cabinet channel: `34001`
- Reply channel: `34002`

If your cabinet hardware differs, edit those values at top of `/cabinet_test/main.lua`.
