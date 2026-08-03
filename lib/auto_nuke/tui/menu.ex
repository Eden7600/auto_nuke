defmodule AutoNuke.Tui.Menu do
  @moduledoc """
  The TUI's task catalogue: every Mix task from the README, with parameter
  prompts. Items invoke the existing `Mix.Tasks.*.run/1` functions with
  string arguments, so argument parsing and validation stay in one place.

  A param spec is `%{label: ..., hint: ..., optional: boolean}`. Optional
  params left blank are dropped from the tail of the argument list (the
  underlying tasks vary their behaviour by argument count).
  """

  alias Mix.Tasks.AutoNuke, as: T

  def items do
    [
      %{
        id: :startup,
        group: "Plant",
        label: "Startup — cold start the reactor",
        params: [
          %{label: "Loops", hint: "blank = all installed; e.g. 1, 1..2, 1,3", optional: true},
          %{label: "Cores", hint: "blank = all loaded bays; e.g. 1..3", optional: true}
        ],
        task: T.Startup,
        # In the TUI, startup ends by handing the plant to supervised
        # operators instead of holding the VM in an infinite wait.
        run_opts: [handoff: :adopt],
        confirm: "Start up the reactor from cold?"
      },
      %{
        id: :loop_start,
        group: "Plant",
        label: "Loop start — bring a loop online",
        params: [%{label: "Loop", hint: "1, 2 or 3", optional: false}],
        task: T.Loop.Start
      },
      %{
        id: :loop_stop,
        group: "Plant",
        label: "Loop stop — take a loop offline",
        params: [%{label: "Loop", hint: "1, 2 or 3", optional: false}],
        task: T.Loop.Stop
      },
      %{
        id: :shutdown,
        group: "Plant",
        label: "Shutdown — stop the entire reactor",
        params: [],
        task: T.Shutdown,
        confirm: "Begin a controlled shutdown of the whole plant?"
      },
      %{
        id: :refuel,
        group: "Plant",
        label: "Refuel — replace spent fuel cells (guided)",
        params: [
          %{label: "Bays", hint: "blank = spent; all; or 1, 3..5", optional: true},
          %{label: "Pool level", hint: "% for hatch work; blank = 50", optional: true}
        ],
        task: T.Refuel,
        confirm: "Refuel the reactor? (Reactor must be shut down and cool.)"
      },
      %{
        id: :refill_condenser,
        group: "Refill",
        label: "Condenser",
        params: [%{label: "Target level", hint: "gauge units", optional: false}],
        task: T.Refill.Condenser
      },
      %{
        id: :refill_core_pool,
        group: "Refill",
        label: "Core pool",
        params: [%{label: "Target level", hint: "may be lower than current", optional: false}],
        task: T.Refill.CorePool
      },
      %{
        id: :refill_core_pool_storage,
        group: "Refill",
        label: "Core pool storage",
        params: [%{label: "Target level", hint: "gauge units", optional: false}],
        task: T.Refill.CorePoolStorage
      },
      %{
        id: :refill_core_vessel,
        group: "Refill",
        label: "Core vessel (primary coolant)",
        params: [%{label: "Target level", hint: "gauge units", optional: false}],
        task: T.Refill.CoreVessel
      },
      %{
        id: :refill_internal,
        group: "Refill",
        label: "Internal tanks (M01/M02/M03)",
        params: [],
        task: T.Refill.Internal
      },
      %{
        id: :refill_primary_cst,
        group: "Refill",
        label: "Primary CST",
        params: [%{label: "Target level", hint: "gauge units", optional: false}],
        task: T.Refill.PrimaryCst
      },
      %{
        id: :refill_reservoir,
        group: "Refill",
        label: "External reservoir",
        params: [%{label: "Target level", hint: "gauge units", optional: false}],
        task: T.Refill.Reservoir
      },
      %{
        id: :refill_secondary,
        group: "Refill",
        label: "Steam generator (secondary)",
        params: [
          %{label: "Target level", hint: "gauge units", optional: false},
          %{label: "Loops", hint: "e.g. 1 or 1..3", optional: false, split: true}
        ],
        task: T.Refill.Secondary
      },
      %{
        id: :refill_truck,
        group: "Refill",
        label: "From cargo truck",
        params: [%{label: "Cargo", hint: "boron, NaOH or fuel", optional: false}],
        task: T.Refill.Truck
      },
      %{
        id: :refill_fuel_cells,
        group: "Refill",
        label: "Fuel cells — per-bay piston/hatch assist",
        params: [%{label: "Core bays", hint: "e.g. all, 1, 3..5", optional: false, split: true}],
        task: T.Refill.FuelCells
      },
      %{
        id: :boron_inject,
        group: "Misc",
        label: "Boron — inject",
        params: [
          %{label: "Target", hint: "ppm", optional: false},
          %{label: "Max rate", hint: "blank = default", optional: true}
        ],
        task: T.Boron.Inject
      },
      %{
        id: :boron_filter,
        group: "Misc",
        label: "Boron — filter out",
        params: [
          %{label: "Target", hint: "ppm", optional: false},
          %{label: "Max speed", hint: "blank = default", optional: true}
        ],
        task: T.Boron.Filter
      },
      %{
        id: :valve,
        group: "Misc",
        label: "Valve — open/close actuated valves",
        params: [
          %{label: "Action", hint: "open or close", optional: false},
          %{label: "Valves", hint: "e.g. A1 B2 DV01, or a group name", optional: false, split: true}
        ],
        task: T.Valve
      },
      # Last, in its own group, well away from the routine plant tasks.
      %{
        id: :meltdown,
        group: "Danger",
        label: "☢ MELTDOWN — cascade the plant into failure",
        params: [
          %{label: "Pace", hint: "%/game-min; blank = 5", optional: true},
          %{label: "Act limit", hint: "game-min per act; blank = 10", optional: true}
        ],
        task: T.Meltdown,
        confirm: "DESTROY the plant? [x] aborts and SCRAMs."
      }
    ]
  end

  @doc "Turn collected answers into the task's argv-style argument list."
  def build_args(item, answers) do
    item.params
    |> Enum.zip(answers)
    |> Enum.flat_map(fn
      {%{split: true}, answer} -> String.split(answer)
      {_param, answer} -> [answer]
    end)
    |> drop_blank_tail()
  end

  @doc "Build the zero-arity function the Runner executes."
  def build_run(item, answers) do
    args = build_args(item, answers)

    case item[:run_opts] do
      nil -> fn -> item.task.run(args) end
      opts -> fn -> item.task.run(args, opts) end
    end
  end

  defp drop_blank_tail(args) do
    args
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end
end
