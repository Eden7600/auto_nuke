# AutoNuke

Automation to run a simulated nuclear power plant in [Nucleares](https://store.steampowered.com/app/1428420/Nucleares/).

## Installation & Usage

- Install [Elixir](https://elixir-lang.org/install.html).
- Run `mix deps.get` to fetch dependencies.
- Start your Nucleares game and enable the webserver.
- Edit `config/dev.exs` to point to your Nucleares webserver.
  - You can run the game and the `AutoNuke` client on different computers, as long as the client can reach the game.

Then start the TUI:

```sh
mix auto_nuke.tui
```

This works the same on Windows (PowerShell), macOS, and Linux — no shell scripts or Erlang distribution required.  It handles both a cold and an already-running reactor:

- **Live dashboard** — core, loops, condenser, tanks, and operator status, updating in real time (and showing OFFLINE/PAUSED/STALLED when appropriate).
- **`[t]` task menu** — run every task listed in the `Tasks` section below, with guided parameter prompts.  Task output streams into a pane; long tasks (like a full startup) can be sent to the background with `[b]` while you watch the dashboard.
- **`[o]` operator menu** — all operators start **off** when the TUI launches.  Enable/disable them individually (with a description of what each one does), adjust their overrides and boost modes, or press `[s]` to start them all under supervision.
- **Demand & health panels** — this hour's energy budget with a projected end-of-hour score, plus core integrity/wear and any active issues.  Sparklines track core temperature, net output, and steam generator pressure.
- **`[h]` plant health view** — the game's own diagnostics: named alarms, active situations, and a per-element maintenance breakdown (integrity, wear, radiation, misalignment/contamination flags) so you can see exactly *what* is degrading, not just an overall number.
- **`[l]` log view** — operator log lines, in a strip on tall terminals and a full-screen overlay on demand.
- **`[d]` drill mode** — trigger the game's chaos events (pump jams, spills, breaker trips, weather...) to stress-test the operators.  Requires a one-time in-game confirmation the first time you enable it.
- **`[S]` SCRAM** — emergency-drop all control rods (disabling the rod-commanding operators first so they can't fight it).
- **Cold start, unified** — running `Startup` from the TUI ends with the supervised operators taking over automatically.  No more Ctrl-C-then-`./start.sh` two-step.

The operators handle all the factors listed in the `Operators` section, below.  Your only concern is to handle the manual things, like deciding when to bring loops up and down, doing maintenance, buying upgrades, etc.

If you see a bunch of `Req` errors about not being able to connect, check that you can reach the Nucleares webserver.

### Classic CLI mode

The pre-TUI workflow still works (and is what the TUI uses under the hood):

- Run `mix auto_nuke.startup` to start up a cold reactor.
- Run `./start.sh` to start the automation on an already-running reactor.
- Run individual tasks via `./task.sh <task>` against the `./start.sh` node.

## Operators

### Core operators

- [`SteamFlow`](lib/auto_nuke/operators/steam_flow.ex) - Manages the MSCV and bypass of each turbine.
  - Power output is managed by adjusting the total combined open percentage of all MSCV valves.
  - Within that total, the per-turbine MSCV setting will be adjusted to try to keep pressure balanced across all steam generators.
  - Turbine bypass will be opened if the combined steam output is too low for the vacuum system (below 50 kg/min), or if a steam generator begins to overpressurise due to too much heat.
- [`CoreTemp`](lib/auto_nuke/operators/core_temp.ex) — Adjusts temperature target based on steam generator pressure.
  - Tries to ensure that all active steam generators average out to 60 bar of pressure.
  - Sends its calculated target to `ControlRods`.
- [`ControlRods`](lib/auto_nuke/operators/control_rods.ex) — Uses control rods to achieve the target temperature.
  - Receives its target temperature from `CoreTemp`.
  - Due to both the target temperature constantly changing, and the difficulty in maintaining a precise temperature, this will unfortunately result in near-constant movement of the control rods.  Sorry for all the noise.
- [`PrimaryPumps`](lib/auto_nuke/operators/primary_pumps.ex) — Adjust the speed of the primary circulation pumps.
  - Sets minimum speed (5%) at 300°C.
  - Sets maximum speed (49%) at 400°C.
  - Everything inbetween scales linearly between those two extremes.
  - The net effect is that heat flow scales with temperature in order to deliver a continuous, stable, and predictable amount of heat.
- [`BoronLevel`](lib/auto_nuke/operators/boron_level.ex) — Increases or decreases boron concentration to maintain reactor control.
  - If control rods are more than 50% inserted, will begin slowly dosing the core with more boron (to hopefully reduce iodine production).
  - If control rods are less than 20% inserted, will begin filtering boron out of the core.
  - Both of these use exponential curves, such that dosing and filtering start out slow, but climb rapidly as you approach 100% and 0% rods, respectively.

### Other operators

- [`CoreFill`](lib/auto_nuke/operators/core_fill.ex) - Maintains fill level in the core.
  - Opens the drain valve if the core is overfilled.
    - This typically happens when boron is being added.
  - Pumps in more coolant if the core is underfilled.
    - This most typically happens at initial startup, when the primary coolant pipes are empty and must be filled before any coolant can be returned to the core.
- [`PCSTFill`](lib/auto_nuke/operators/pcst_fill.ex) - Maintains fill level in the Primary Coolant Storage Tank
  - This is to ensure `CoreFill` always has somewhere to pump from / drain into.
  - Opens the drain valve if the tank is overfilled.
    - This typically happens when the core is being drained (into this tank).
  - Pumps in more coolant if the core is underfilled.
    - Not very common, but can happen if you underfilled it at the start of a non-ready game.
- [`SecondaryFill`](lib/auto_nuke/operators/secondary_fill.ex) - Maintains fill level in each steam generator.
  - Primarily targets the "proper" pump speed, which is based on capacity + steam outlet.
    - At the start of the game, this is half the steam outlet, e.g. 50 kg/min = 25% pump speed.
    - This changes as you upgrade the pumps.
  - Adds a tiny 1% bias (higher or lower) to try to push fill level towards 50.
  - If fill level gets **really** low or high (under 30% or over 70% respectively), it's capable of scaling pump speed all the way to 100% or 0%, respectively.
- [`VacuumTank`](lib/auto_nuke/operators/vacuum_tank.ex) - Maintains vacuum in the condenser.
  - Has two modes: Pump mode, and CRV mode.
  - In pump mode, it adjust OMSI/SMSI to maintain 50% retention tank level.
  - In CRV mode, it adjusts OMSI/SMSI to maintain 99% vacuum.
  - Automatically switches modes based on total steam flow.
- [`CondenserFill`](lib/auto_nuke/operators/condenser_fill.ex) - Manages the condenser fill level.
  - Tries to maintain a level between 35% and 65% (i.e. within 15% of half full).
  - If level increases beyond 65%, opens the drain valve until it drops to below 60%.
  - If level drops below 35%, runs the freight pump until level is back up to 40%.
- [`EmergencyPower`](lib/auto_nuke/operator/emergency_power.ex) - Backup power management.
  - Detects a station blackout (no external or turbine supply — batteries draining) and starts the emergency diesel generators.
  - Stops the generators it started once normal supply returns; generators you started by hand are left alone.
  - Warns about low diesel fuel and pending generator maintenance.
- [`ResistorBanks`](lib/auto_nuke/operator/resistor_banks.ex) - Resistor bank management.
  - Keeps the resistor banks off while supply tracks the target (power fed to resistors is power not sold).
  - Enables them whenever supply strays outside ±8% of SteamFlow's current target — proactively, since the plant gets in trouble at 10% — and disables them again once supply has hugged the target for a sustained stretch.
- [`CondenserCooling`](lib/auto_nuke/operators/condenser_cooling.ex) - Manages the condenser cooling pump.
  - Runs the pump at the lowest speed it can get away with (down to 10%) without temperature climbing.
  - Uses a probe/backoff strategy, where it will (very slowly) reduce speed until temperature starts climbing, then back off and leave it alone for 15+ minutes at a time.
  - The goal is just to reduce wear on the cooling pump, since you can't service it without taking the plant offline.

## Tasks

### Startup / shutdown

- [`mix auto_nuke.startup`](lib/mix/tasks/startup.ex) — Starts a cold reactor.

These need to be run via `task.sh` in order to set up communication with a running `AutoNuke` process:

- [`./task.sh auto_nuke.loop.start`](lib/mix/tasks/loop/start.ex) — Starts a loop (steam generator + turbine) and connects it to the grid.
- [`./task.sh auto_nuke.loop.stop`](lib/mix/tasks/loop/stop.ex) — Disconnects a loop and safely shuts it down.
- [`./task.sh auto_nuke.shutdown`](lib/mix/tasks/shutdown.ex) — Begins a controlled shutdown of the entire plant.

### Refilling tanks

- [`mix auto_nuke.refill.condenser`](lib/mix/tasks/refill/condenser.ex) — Refills the condenser.
- [`mix auto_nuke.refill.core_pool`](lib/mix/tasks/refill/core_pool.ex) — Refills or empties the core pool.
- [`mix auto_nuke.refill.core_pool_storage`](lib/mix/tasks/refill/core_pool_storage.ex) — Refills the Core Pool Storage tank.
- [`mix auto_nuke.refill.core_vessel`](lib/mix/tasks/refill/core_vessel.ex) — Refills the core vessel (i.e. primary coolant).
- [`mix auto_nuke.refill.internal`](lib/mix/tasks/refill/internal.ex) — Refills some combination of tanks using the M01/M02/M03 valves.
- [`mix auto_nuke.refill.primary_cst`](lib/mix/tasks/refill/primary_cst.ex) — Refills the Primary Coolant Storage Tank.
- [`mix auto_nuke.refill.reservoir`](lib/mix/tasks/refill/reservoir.ex) — Refills the external reservoir.
- [`mix auto_nuke.refill.secondary`](lib/mix/tasks/refill/secondary.ex) — Refills a given steam generator.
- [`mix auto_nuke.refill.truck`](lib/mix/tasks/refill/truck.ex) — Loads liquids from a cargo truck.

### Miscellaneous

- [`mix auto_nuke.refuel`](lib/mix/tasks/refuel.ex) — Guided reactor refueling: safety checks, fuel report, pool level, pistons and hatches.  (The crane has no API — the cell swaps are up to you.)
- [`mix auto_nuke.boron.inject`](lib/mix/tasks/boron/inject.ex) — Injects boron into the core.
- [`mix auto_nuke.boron.filter`](lib/mix/tasks/boron/filter.ex) — Filters boron out of the core.
- [`mix auto_nuke.valve`](lib/mix/tasks/valve.ex) — Opens or closes valves with electric actuators.
