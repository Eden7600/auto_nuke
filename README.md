# AutoNuke

Automation to run a simulated nuclear power plant in [Nucleares](https://store.steampowered.com/app/1428420/Nucleares/).

## Installation & Usage

- Run `mix deps.get`. 
- Start your Nucleares game and enable the webserver.
- Edit `config/dev.exs` to point to your Nucleares webserver.
  - You can run the game and the `AutoNuke` client on different computers, as long as the client can reach the game.

Now you have one of two choices:
- Run `mix auto_nuke.startup` to start up a cold reactor.
- Run `./start.sh` to start the automation on an already-running reactor.

In either case, if you see a bunch of `Req` errors about not being able to connect, check that you can reach the Nucleares webserver.

Once you run `./start.sh`, the `AutoNuke` operators will take over and begin automation.  They'll handle all the factors listed in the `Operators` section, below.  Your only concern is to handle the manual things, like choosing a target core factor, deciding when to bring loops up and down, etc.

## Operators

- [`CoreFactor`](lib/auto_nuke/operators/core_factor.ex) - Controls core reactivity.
  — Maintains a steady core factor above all.
  - Performs gradual rod changes to deal with changing conditions (xenon buildup, loss of fissile material, etc).
  - To change it, you can manually set a new target (`CoreFactor.set_target/1`), or you can initiate a controlled drift (`CoreFactor.drift/1`) to slowly change factor over time.
  - The startup script (below) uses a large `drift` to get up to the target temperature.
- [`CoreTemp`](lib/auto_nuke/operators/core_temp.ex) — Adjusts primary pumps based on speed.
  - Sets minimum speed (10%) at 320°C.
  - Sets maximum speed (49%) at 400°C.
  - Everything in between uses a smooth linear scale (e.g. around 30% at 360°C).
  - The net effect is just to bias the reactor towards 360°C while delivering a continuous, stable amount of heat (at a given core factor).
- [`SteamFlow`](lib/auto_nuke/operators/steam_flow.ex) - Scales power up and down to handle demand.
  - Each turbine will have its MSCV scaled up and down to meet power demand.
  - This happens on a round-robin basis, meaning that e.g. if all turbines are at MSCV 5 and it needs a bit more power, it'll increase one of them to 6 but keep the others at 5.
  - Also controls turbine bypass to maintain at least 50 kg/min steam flow when there's very low power demand, and to prevent any steam generator from reaching saturation pressure due to too much heat.
- [`SecondaryFill`](lib/auto_nuke/operators/secondary_fill.ex) - Maintains fill level in each steam generator.
  - Primarily targets the "proper" pump speed, which is based on capacity + steam outlet.
    - At the start of the game, this is half the steam outlet, e.g. 50 kg/min = 25% pump speed.
    - This changes as you upgrade the pumps.
  - Adds a tiny 1% bias (higher or lower) to try to push fill level towards 50.
  - If fill level gets **really** low or high (under 30% or over 70% respectively), it's capable of scaling pump speed all the way to 100% or 0%, respectively.
- [`VacuumTank`](lib/auto_nuke/operators/vacuum_tank.ex) - Maintains vacuum in the condennser.
  - Has two modes: Pump mode, and CRV mode.
  - In pump mode, it adjust OMSI/SMSI to maintain 50% retention tank level.
  - In CRV mode, it adjusts OMSI/SMSI to maintain 99% vacuum.
  - Automatically switches modes based on total steam flow.
- [`CondenserCooling`](lib/auto_nuke/operators/condenser_cooling.ex) - Manages the condenser cooling pump.
  - Runs the pump at the lowest speed it can get away with (down to 10%) without temperature climbing.
  - Uses a probe/backoff strategy, where it will (very slowly) reduce speed until temperature starts climbing, then back off and leave it alone for 15+ minutes at a time.
  - Sole aim is just to reduce wear on the cooling pump, since you can't service it without taking the plant offline.

## Tasks

### Startup / shutdown

- [`mix auto_nuke.startup`](lib/mix/tasks/startup.ex) — Starts a cold reactor.

These need to be run via `task.sh` in order to set up communication with a running `AutoNuke` process:

- [`./task.sh auto_nuke.loop.start`](lib/mix/tasks/loop/start.ex) — Starts a loop (steam generator + turbine) and connects it to the grid.
- [`./task.sh auto_nuke.loop.stop`](lib/mix/tasks/loop/stop.ex) — Disconnects a loop and safely shuts it down.

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

- [`mix auto_nuke.boron.inject`](lib/mix/tasks/boron/inject.ex) — Injects boron into the core.
- [`mix auto_nuke.boron.filter`](lib/mix/tasks/boron/filter.ex) — Filters boron out of the core.
- [`mix auto_nuke.valve`](lib/mix/tasks/valve.ex) — Opens or closes valves with electric actuators.
