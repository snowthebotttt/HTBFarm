# HTBFarm

A Windower 4 addon that runs a six-character party through the Garuda
High-Tier Battlefield (Wind Protocrystal, Cloister of Gales) on a loop:
buy the entry key item, travel out, enter the battlefield, fight, run
back, warp home, repeat — all six characters synchronized.

> **Private-server tool.** This addon automates travel, key-item purchase,
> battlefield entry, and combat hand-off. It is built for private servers
> where automation is permitted, and it leans on the Silmaril multibox
> program for two steps. Use on retail or on servers that prohibit
> automation is at your own risk.

## How it works

One addon file runs on all six clients. Each character reads its own name
and decides its role from `LEADER_NAME` in the config — the leader drives
the shared actions (warps, reflects), and everyone reports progress to the
leader over Windower's IPC messaging so the party stays in lockstep.

The loop is a state machine. At each synchronization point the leader
waits until all party members have reported before advancing the group,
so nobody is left behind. Movement uses Windower's own `windower.ffxi.run`
API following recorded coordinate waypoints — no simulated keystrokes.

### Cycle

1. **Buy KI** — everyone runs to Trisvain (N. San d'Oria). The leader
   fires `//sm all reflect Avatar`; each client confirms the *Avatar
   phantom gem* appears in its key items.
2. **Travel out** — everyone runs to the home point; the leader fires
   `//hp a cape` (superwarp moves the whole party to Cape Teriggan).
3. **Approach** — everyone runs through Cape Teriggan into the Cloister of
   Gales and up to the Wind Protocrystal.
4. **Enter** — the leader fires `//sm all reflect Garuda`; each client
   detects its own jump into the battlefield instance.
5. **Fight** — everyone runs to the buff spot; when all are inside, the
   leader fires `//sm all on` to start the combat program.
6. **Exit** — each client detects its own ejection when the fight ends,
   then runs back out of the Cloister to the Cape Teriggan home point.
7. **Warp home** — the leader fires `//hp a northern sand 2`; the party
   lands back in San d'Oria and the next cycle begins.

Any character dying, timing out, or hitting an unexpected zone broadcasts
a halt to the whole party and stops the combat program.

## Requirements

- [Windower 4](https://www.windower.net/)
- The addon loaded on **all six** clients (autoload recommended)
- **Silmaril** multibox program, providing:
  - `//sm all reflect Avatar` — buys the KI on every character
  - `//sm all reflect Garuda` — enters the battlefield on every character
  - `//sm all on` / `//sm all off` — starts/stops the combat program
- A superwarp addon providing `//hp a cape` and `//hp a northern sand 2`
- All six characters in the same party, standing in Northern San d'Oria

Why the reflects: this server validates the packet sequence counter on the
KI-purchase and battlefield-entry code paths, so directly injected response
packets are silently dropped there. Silmaril's reflect produces properly
sequenced client packets the server accepts, and it also lets characters
that cannot meet the purchase requirement normally still obtain the gem.

## Installation

1. Create `Windower4/addons/HTBFarm/` and put `HTBFarm.lua` inside it.
2. Repeat on (or share the folder across) all six game installs.
3. Set `LEADER_NAME` in the config to your leader's character name.
4. `//lua load htbfarm` on each client — or add it to autoload.
   On load, each client logs its detected role.

## Usage

Get all six characters into a party in Northern San d'Oria, then on the
**leader only**:

```
//htb start
```

The leader broadcasts the start to the other five and the loop begins.
`//htb stop` from *any* client halts the whole party.

### Commands

| Command | Description |
|---|---|
| `//htb start` | (Leader) start the party loop. Followers refuse and point to the leader. |
| `//htb stop` | Stop all six clients (broadcast). |
| `//htb unstick` | Force-close a stuck NPC menu on this client. |
| `//htb status` | Print this client's role and state. |
| `//htb hud` | Toggle the HUD. |

The leader's HUD shows party sync progress (e.g. `Party synced: 4/6`), so
you can see who is lagging at each step.

## Configuration

All settings are near the top of `HTBFarm.lua`.

| Setting | Purpose |
|---|---|
| `LEADER_NAME` | Character that leads the party (drives warps and reflects). |
| `KI_NAME` | Key item to buy (`Avatar phantom gem`). |
| `REFLECT_KI_CMD` / `REFLECT_CMD` | Silmaril commands for KI buy / entry. |
| `SUPERWARP_OUT` / `SUPERWARP_HOME` | Superwarp commands out and home. |
| `FIGHT_ON_CMD` / `FIGHT_OFF_CMD` | Combat program start/stop. |
| `LEG_*` tables | Recorded coordinate waypoints for each running leg. |
| `BC_X_THRESHOLD` | X coordinate splitting the Cloister from the battlefield instance (used to detect entry/ejection). |
| `TIMEOUTS` | Per-state safety timeouts, in seconds. |

### Changing the fight or difficulty

Difficulty is selected by the Silmaril reflect you saved, not by this
addon — record the reflect for the tier you want and point `REFLECT_CMD`
at it. To farm a different battlefield entirely you would re-record the
route legs (see below), the KI name, and both reflects.

### Re-recording routes

The `LEG_*` waypoint tables were extracted from a coordinate recording of
one manual run. If NPC positions or your path change, record a new run
with a position logger, split it per zone, and replace the relevant `LEG_*`
table. Keep waypoints at each turn; straight corridors need only their
endpoints.

## Troubleshooting

- **Only the leader acts** — the reflects must be `//sm all reflect ...`
  (party-wide), not `//sm reflect ...` (caller only).
- **A character stalls at the KI NPC** — it never got the gem after the
  reflect. Usually a resource shortage; the party halts after the wait
  timeout with a named reason in that client's log.
- **`unexpected zone change ... during state ...`** — a warp or zone line
  fired in a state that did not expect it; the party halts. Check that the
  superwarp commands and start location are correct.
- **`never zoned into ...` / `timed out walking to waypoint`** — someone
  got stuck on terrain; add an intermediate waypoint to that leg.
- **Followers refuse `//htb start`** — you started on a follower. Start on
  the `LEADER_NAME` character.
- **Party size wrong** — the count is captured at `//htb start` from the
  live party list. Make sure exactly the intended members are partied and
  present before starting; a crashed/offline member left in the party will
  make the leader wait forever.

## A note on scale

This loop generates gil and loot continuously across six characters. Even
on automation-tolerant servers, large-scale generation is the kind of
thing that draws attention and affects the server economy. Running in
sessions rather than around the clock is the sensible approach, and it is
worth knowing your merit economy — six gems per cycle is a real drain, and
a character that runs short will cleanly halt the party rather than break.

## Credits

Written by Jared, with Claude (Anthropic). Battlefield entry and KI
purchase rely on the Silmaril multibox program; the KI affordability logic
was informed by Ivaar's `htmb` addon.
