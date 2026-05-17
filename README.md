
# BlueMap Minimap

Minecraft minimap and autopilot for Create Aeronautics airships, using BlueMap
and CC:Tweaked.

## Screenshots

<img width="1920" height="1081" alt="2026-05-12_20 14 04" src="https://github.com/user-attachments/assets/510590df-f567-4ef9-8bbd-5784d08e58b2" />
<img width="1920" height="1081" alt="2026-05-12_20 14 23" src="https://github.com/user-attachments/assets/e6a0f4c1-0c56-4d83-beb9-06f049f47385" />

## Features

- Map view, north-up, ship-centered. Zoom and LOD buttons.
- OSD: position, heading, altitude, burner level, speed.
- Altitude tape with ground line and burner-level marker.
- Speedometer dial.
- Tappable waypoints from `waypoints.json` and BlueMap markers.
- Autopilot: climbs to a cruise AGL setpoint, PI-holds altitude, lands on arrival.
- ALT button for altitude-only hold at current altitude.
- Pocket remote mirrors ship state over rednet and forwards taps as commands.

## Controls

| Button | Action |
|---|---|
| `+` / `-` | Zoom in/out |
| `L1`/`L2`/`L3` | Cycle BlueMap LOD |
| `ALT` | Toggle altitude hold |
| `AUTO` | Engage autopilot (needs a target) |
| `X` | Clear target |

Tap a waypoint dot or another player to set them as the target.

## CLI

The same commands work from the ship CC, the pocket, or any computer with the
shared `controlSecret`. Type `minimap` followed by a subcommand:

| Command | Action |
|---|---|
| `minimap goto X Z` | Autopilot to coordinate X,Z |
| `minimap wp <name>` | Autopilot to a named waypoint (tab-completes) |
| `minimap burner N` | Drive burner to level N (0-15) |
| `minimap hold [alt]` | Toggle altitude hold (optional explicit altitude) |
| `minimap stop` | Disengage autopilot, altitude hold, and manual burner |
| `minimap status` | Print position / heading / mode |
| `minimap --help` | Full list |

Tab completion is registered on boot for `minimap <sub>` and waypoint names.

## Dependencies

- [BlueMap](https://bluemap.bluecolored.de/)
- [Create Aeronautics](https://github.com/Sciecode/create-aeronautics)
- [CC:Tweaked](https://tweaked.cc/)
- Docker

## Server setup

1. Copy `.env.example` to `.env` and fill in the values.
2. `docker compose up -d --build`
3. `curl http://your-host:5055/health` returns `{"ok": true}`.

`waypoints.json` is volume-mounted into the container. Format in
`waypoints.example.json`. Restart the container after editing.

## Ship CC computer

Peripherals (any side, or via wired modems):

- Advanced monitor
- `altitude_sensor`, `velocity_sensor`, `navigation_table` with a compass
- Two `redstone_relay`s on a wired modem network:
  - Relay 0: forward/back/left/right WASD redstone links
  - Relay 1: `liftUp`, `liftDown`, and a `liftLevel` analog input for the burner
- A wireless or ender modem for the pocket remote

Install:

```
> wget http://your-host:5055/startup.lua startup.lua
> reboot
```

Tune via `minimap.cfg`:

- `channels` / `inputs`: relay and side mapping
- `hoverBurnerLevel`: starting burner level for the PI controller. Find by trial.
- `liftKp`, `liftKi`, `liftKd`: altitude PI+D gains. Lower Kp and higher Kd if it
  oscillates; Ki absorbs altitude-dependent burner equilibrium so AUTO doesn't
  stall short of target over high terrain.
- `cruiseAltitudeAboveGround`: target AGL when AUTO is engaged
- `airshipName`, `controlSecret`: pairing values (see below)

## Pocket

Slot an ender modem into the back of an advanced pocket computer.

```
> wget http://your-host:5055/startup-pocket.lua startup.lua
> reboot
```

## Pairing

Both `minimap.cfg` and `minimap-pocket.cfg` have `airshipName` and
`controlSecret`. The ship hosts on rednet as `airship-<airshipName>`; the
pocket looks that up and signs each command with `controlSecret`. The defaults
(`main` / `changeme`) are public, so change both on each device before flying.

## Multi-user

For multiple players on one BlueMap proxy:

- Blank `CLIENT_PLAYER_NAME` in `.env`
- Each CC sets its own `playerName` in `minimap.cfg`
- Each player picks their own `airshipName` and `controlSecret`
