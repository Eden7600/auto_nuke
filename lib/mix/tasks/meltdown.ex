defmodule Mix.Tasks.AutoNuke.Meltdown do
  @shortdoc "Deliberately destroy the plant (staged cascade)"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.API.SteamGen
  alias AutoNuke.Smoother
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.TaskUI.ProgressBar.Config, as: PBConfig
  alias AutoNuke.Operator, as: Op

  @moduledoc """
  Drives the plant into a cascading failure, in parts.

      mix auto_nuke.meltdown [pace %/min] [patience min]

  A sandbox toy: it exists to find out how the game behaves at its
  limits, and whether you can pull the plant back from the brink. It
  will wreck the reactor in your save.

  It doesn't just yank the rods. It works the plant to death from the
  outside in, letting each stage fully develop before starting the next:

    * **Part I — Maximum output.** Resistor banks on, then the plant is
      asked for everything it can safely make: grid demand plus the full
      absorption capacity of the banks. The operators drive it up there
      and we wait for the power to genuinely plateau.
    * **Part II — Destroy the turbines.** Condenser cooling off, vacuum
      pump stopped and the condensate return valve opened, then we wait
      for the condenser vacuum to collapse. The turbines keep spinning
      into the rising backpressure — tripping them would *protect* them.
      The turbine bypass is shut so no steam can route around them, and
      the emergency generators are started on the way down, at 80%
      vacuum, so the plant still has power once the turbines give up.
    * **Part III — Overpressure.** Feedwater to maximum, vents shut,
      then the main steam control valves slowly choked, and we watch the
      steam generator pressure climb with nowhere to go.
    * **Part IV — Heat sink.** The core pool is drained away.
    * **Part V — Prompt criticality.** Boron filtered out, rods
      withdrawn, primary circulation throttled to nothing.
    * **Part VI — Aftermath.** Core temperature, then core integrity,
      watched to the end.

  Operators are stood down one at a time, each at the moment it becomes
  an obstacle — so the plant is running itself, hard, for as long as
  possible.

  `pace` is how fast valves, rods and pumps are driven, and `patience`
  is how long any one stage may take before we give up on it and press
  on. Both are in minutes of real time at 1× simulation speed.
  """

  # Ticks arrive five times per real second at 1x simulation speed.
  @ticks_per_minute 5 * 60

  @default_pace 20.0
  @default_patience 5.0

  # Output has plateaued when a window of samples opens and closes within
  # this many MW of each other, sustained for @plateau_hold ticks.
  @plateau_window 40
  @plateau_threshold_mw 1.0
  @plateau_hold @ticks_per_minute

  # Vacuum (a 0-1 fraction) has collapsed far enough below this that the
  # turbines are done for; no need to watch it all the way down:
  @vacuum_gone 0.6
  # Get the diesels running before the turbines stop carrying the plant:
  @generator_start_vacuum 80.0
  # Watch steam generator pressure climb towards this:
  @pressure_ceiling 120.0
  # A steam generator counts as "live" above this pressure:
  @live_pressure 5.0
  # Pressure milestones worth shouting about:
  @pressure_milestones [65, 70, 75, 80, 90, 100, 120]

  @integrity_floor 1.0
  @loops 1..3

  def run(args), do: run(args, [])

  def run([], opts), do: meltdown(@default_pace, @default_patience, opts)
  def run([pace], opts), do: meltdown(parse(pace, @default_pace), @default_patience, opts)

  def run([pace, patience], opts),
    do: meltdown(parse(pace, @default_pace), parse(patience, @default_patience), opts)

  defp parse("", default), do: default

  defp parse(str, _default) do
    case Float.parse(String.trim(str)) do
      {value, _} when value > 0 -> value
      _ -> Mix.raise("Expected a positive number.")
    end
  end

  def meltdown(pace, patience, opts \\ []) do
    UI.init()
    UI.log_to_file("startup.log")

    check_reactor_live()

    UI.console("☢ CASCADE SEQUENCE")
    UI.warn("Deliberately destroying the plant.  [x] aborts and SCRAMs.")

    guard = start_abort_guard(Keyword.get(opts, :guard, true))

    state = %{
      pace: pace,
      # Per-tick movement, and the tick budget for any one stage:
      step: pace / @ticks_per_minute,
      limit: round(patience * @ticks_per_minute),
      loops: live_loops()
    }

    UI.notice("Live steam generators: #{inspect(state.loops)}")

    part_1_maximum_output(state)
    part_2_destroy_turbines(state)
    part_3_overpressure(state)
    part_4_heat_sink(state)
    part_5_prompt_criticality(state)
    part_6_aftermath(state)

    stand_down_guard(guard)
    UI.notice("Cascade complete.")
  end

  defp check_reactor_live do
    UI.console("Preconditions")

    UI.test("Reactor Running", fn ->
      if API.get_boolean("CORE_CRITICAL_MASS_REACHED"), do: :pass, else: :fail
    end)
    |> case do
      :pass -> :ok
      :fail -> Mix.raise("The reactor isn't critical — there's nothing to melt down.")
    end
  end

  defp live_loops do
    Enum.filter(@loops, fn loop ->
      safe_number(fn -> SteamGen.for_loop(loop) |> SteamGen.get_pressure() end, 0.0) >=
        @live_pressure
    end)
  end

  # -- Part I: wring every megawatt out of the plant --------------------------

  defp part_1_maximum_output(state) do
    UI.console("PART I — MAXIMUM OUTPUT")

    # The banks are where the surplus goes: with them on, "safe maximum"
    # is grid demand plus everything they can absorb.
    capacity_mw = Mix.Tasks.AutoNuke.Startup.enable_resistor_bank()
    stand_down(Op.ResistorBanks, "Resistor Banks Operator")

    demand_mw = safe_number(fn -> API.Power.get_demand_mw() end, 0.0)
    target_mw = demand_mw + capacity_mw

    UI.set(
      "Power Target",
      "#{fmt(target_mw)} MW  (demand #{fmt(demand_mw)} + banks #{fmt(capacity_mw)})"
    )

    case safe(fn -> Op.SteamFlow.set_target_override_mw(target_mw, :never) end) do
      :err ->
        UI.warn("Steam Flow Operator isn't running — can't drive the plant up.")

      _ ->
        UI.notice("Operators are now pushing the plant to its limit.")

        bar(
          "Plant Output",
          PBConfig.target(total_generation_mw(), target_mw, " MW", 1),
          fn -> total_generation_mw() end,
          plateau_done_fn(),
          state.limit
        )

        UI.success("Output settled at #{fmt(total_generation_mw())} MW.")
    end
  end

  # Accumulates its own history: true once output has been flat for a
  # sustained stretch, not merely flat for an instant.
  defp plateau_done_fn do
    fn value ->
      history = Process.get(:plateau, Smoother.new(@plateau_window)) |> Smoother.add(value)
      held = if plateau?(history), do: Process.get(:plateau_held, 0) + 1, else: 0

      Process.put(:plateau, history)
      Process.put(:plateau_held, held)

      held >= @plateau_hold
    end
  end

  @doc """
  Has output plateaued? True once a full window of samples opens and
  closes within `#{@plateau_threshold_mw}` MW — a partial window never
  counts, so a slow climb can't be mistaken for a plateau.
  """
  def plateau?(%Smoother{size: size, max: max}) when size < max, do: false

  def plateau?(history) do
    abs(Smoother.rate_of_change(history)) < @plateau_threshold_mw
  end

  @doc false
  def plateau_window, do: @plateau_window

  defp total_generation_mw do
    @loops
    |> Enum.map(&safe_number(fn -> API.Generator.get_power_kw(&1) end, 0.0))
    |> Enum.sum()
    |> Kernel./(1000)
  end

  # -- Part II: take the vacuum away from the turbines ------------------------

  defp part_2_destroy_turbines(state) do
    UI.console("PART II — DESTROY THE TURBINES")

    stand_down(Op.VacuumTank, "Vacuum Tank Operator")
    stand_down(Op.CondenserCooling, "Condenser Cooling Operator")

    # With no cooling the condenser can't condense, so the vacuum has
    # nothing holding it up.
    cooling_pump = API.Pumps.condenser_cooling()
    UI.set("Condenser Cooling Pump", "OFF")
    safe(fn -> API.Pumps.set_speed(cooling_pump, 0) end)
    safe(fn -> API.Pumps.set_switch(cooling_pump, false) end)

    UI.set("Condenser Vacuum Pump", "STOP")
    safe(fn -> API.VacuumPump.stop() end)

    UI.set("Condensate Return Valve", "OPEN")
    safe(fn -> API.Valves.set_open_percent(API.Valves.crv(), 100) end)

    # The bypass exists to route steam around the turbines and spare
    # them. Shut it: everything goes through the turbines from here.
    UI.set("Turbine Bypass", "SHUT")

    Enum.each(state.loops, fn loop ->
      safe(fn -> API.Valves.set_open_percent(API.Valves.turbine_bypass(loop), 0) end)
    end)

    UI.notice("Vacuum is on its own now.  All steam goes through the turbines.")

    bar(
      "Condenser Vacuum",
      PBConfig.target(vacuum_percent(), @vacuum_gone * 100, "%", 1),
      fn -> watch_vacuum() end,
      fn value -> value <= @vacuum_gone * 100 end,
      state.limit
    )

    UI.warn("Condenser vacuum has collapsed (#{fmt(vacuum_percent())}%).  Turbines are done.")
  end

  defp vacuum_percent do
    safe_number(fn -> API.VacuumPump.get_vacuum_level() end, 0.0) * 100
  end

  # Reports vacuum, and gets the diesels running on the way down: once
  # the turbines stop carrying the plant, everything else needs power to
  # keep the cascade going.
  defp watch_vacuum do
    vacuum = vacuum_percent()

    if vacuum <= @generator_start_vacuum and not Process.get(:generators_started, false) do
      Process.put(:generators_started, true)
      start_emergency_generators()
    end

    vacuum
  end

  defp start_emergency_generators do
    case safe(fn -> Op.EmergencyPower.generator_statuses() end) do
      statuses when is_list(statuses) ->
        case for {gen, "INACTIVO"} <- statuses, do: gen do
          [] ->
            UI.notice("No idle emergency generators to start.")

          idle ->
            UI.warn("Vacuum below #{round(@generator_start_vacuum)}% — starting generators #{inspect(idle)}.")

            Enum.each(idle, fn gen ->
              safe(fn -> API.put("EMERGENCY_GENERATOR_#{gen}_START_STOP", "START") end)
            end)
        end

      _ ->
        UI.notice("Couldn't read the emergency generators.")
    end
  end

  # -- Part III: overpressure the steam generators ----------------------------

  defp part_3_overpressure(%{loops: []}) do
    UI.console("PART III — OVERPRESSURE")
    UI.notice("No live steam generators; skipping the secondary side.")
  end

  defp part_3_overpressure(state) do
    UI.console("PART III — OVERPRESSURE")

    # These two would undo the choking and the flooding respectively.
    stand_down(Op.SteamFlow, "Steam Flow Operator")
    stand_down(Op.SecondaryFill, "Secondary Fill Operators")

    UI.set("Feedwater Pumps", "MAXIMUM")

    Enum.each(state.loops, fn loop ->
      safe(fn -> API.Pumps.secondary(loop) |> API.Pumps.set_speed(100) end)
    end)

    UI.set("Pressure Relief Vents", "SHUT")

    Enum.each(state.loops, fn loop ->
      safe(fn -> SteamGen.for_loop(loop) |> SteamGen.set_vent_open(false) end)
    end)

    # The bar drives the ramp: each sample closes the outlets a little
    # further and reports how far they've shut.
    sgs = Enum.map(state.loops, &SteamGen.for_loop/1)

    bar(
      "Steam Outlets",
      PBConfig.reverse_percent(),
      fn -> choke_step(sgs, state.step) end,
      fn opening -> opening <= 0.0 end,
      state.limit
    )

    UI.success("Steam outlets shut.")

    bar(
      "Steam Pressure",
      PBConfig.target(max_pressure(state.loops), @pressure_ceiling, " bar", 1),
      fn -> watch_pressure(state.loops) end,
      fn pressure -> pressure >= @pressure_ceiling end,
      state.limit
    )
  end

  # Only the MSCVs move here — the bypass was shut in Part II and stays
  # shut, so steam has no path around the turbines.
  defp choke_step(sgs, step) do
    opening = Process.get(:opening, 100.0) - step
    opening = max(opening, 0.0)
    Process.put(:opening, opening)

    rounded = Float.round(opening, 1)

    Enum.each(sgs, fn sg ->
      safe(fn -> API.Valves.set_open_percent(sg.mscv, rounded) end)
      safe(fn -> API.Valves.set_open_percent(sg.bypass, 0) end)
    end)

    opening
  end

  defp max_pressure(loops) do
    loops
    |> Enum.map(&safe_number(fn -> SteamGen.for_loop(&1) |> SteamGen.get_pressure() end, 0.0))
    |> Enum.max(fn -> 0.0 end)
  end

  # Reports the highest steam generator pressure, shouting as it passes
  # each milestone.
  defp watch_pressure(loops) do
    pressure = max_pressure(loops)
    seen = Process.get(:milestones, MapSet.new())

    seen =
      @pressure_milestones
      |> Enum.filter(&(pressure >= &1 and not MapSet.member?(seen, &1)))
      |> Enum.reduce(seen, fn milestone, acc ->
        UI.warn("Steam generator pressure past #{milestone} bar!")
        MapSet.put(acc, milestone)
      end)

    Process.put(:milestones, seen)
    pressure
  end

  # -- Part IV: take away the heat sink ---------------------------------------

  defp part_4_heat_sink(state) do
    UI.console("PART IV — HEAT SINK")

    UI.set("Core Pool", "DRAIN")
    safe(fn -> API.put("CORE_POOL_PUMP", "REMOVE") end)

    pool = API.Vessels.core_pool()

    bar(
      "Core Pool",
      PBConfig.reverse_percent(),
      fn -> safe_number(fn -> API.Vessels.get_fill_percent(pool) end, 0.0) end,
      fn percent -> percent <= 1.0 end,
      state.limit
    )

    UI.warn("Core pool drained.  External cooling is gone.")
  end

  # -- Part V: prompt criticality ---------------------------------------------

  defp part_5_prompt_criticality(state) do
    UI.console("PART V — PROMPT CRITICALITY")

    # The last of the supervision goes now.
    stand_down(Op.ControlRods, "Control Rods Operator")
    stand_down(Op.CoreTemp, "Core Temperature Operator")
    stand_down(Op.PrimaryPumps, "Primary Pumps Operator")
    stand_down(Op.BoronLevel, "Boron Level Operator")

    UI.set("Boron Filtering", "MAXIMUM")
    safe(fn -> API.put("CHEM_BORON_FILTER_ORDERED_SPEED", 100) end)

    pumps = Enum.map(@loops, &API.Pumps.primary/1)

    bar(
      "Control Rods",
      PBConfig.reverse_percent(),
      fn -> rods_and_pumps_step(pumps, state.step) end,
      fn actual -> actual <= 0.1 end,
      state.limit
    )

    UI.warn("Rods out, coolant stopped.")
  end

  # Drives the rods out and the primary pumps down together, reporting
  # actual rod position.
  defp rods_and_pumps_step(pumps, step) do
    ordered = Process.get(:rods, safe_number(fn -> API.get_float("RODS_POS_ACTUAL") end, 100.0))
    ordered = max(ordered - step, 0.0)
    Process.put(:rods, ordered)
    safe(fn -> API.put("RODS_ALL_POS_ORDERED", Float.round(ordered, 1)) end)

    speed = Process.get(:pump_speed, 100.0)
    speed = max(speed - step, 0.0)
    Process.put(:pump_speed, speed)
    Enum.each(pumps, fn pump -> safe(fn -> API.Pumps.set_speed(pump, Float.round(speed, 1)) end) end)

    safe_number(fn -> API.get_float("RODS_POS_ACTUAL") end, 0.0)
  end

  # -- Part VI: aftermath ------------------------------------------------------

  defp part_6_aftermath(state) do
    UI.console("PART VI — AFTERMATH")

    temp_max = safe_number(fn -> API.get_float("CORE_TEMP_MAX") end, 550.0)

    bar(
      "Core Temperature",
      PBConfig.target(core_temp(), temp_max, "°C", 1),
      fn -> core_temp() end,
      fn temp -> temp >= temp_max or beyond_saving?() end,
      state.limit
    )

    UI.warn("Core is over its maximum temperature.")

    bar(
      "Core Integrity",
      PBConfig.reverse_percent(),
      fn -> core_integrity() end,
      fn _integrity -> beyond_saving?() end,
      state.limit * 3
    )

    if beyond_saving?() do
      UI.warn("Core destroyed.")
    else
      UI.notice("Still holding on.  Leaving it to burn.")
    end
  end

  defp core_temp, do: safe_number(fn -> API.get_float("CORE_TEMP") end, 0.0)
  defp core_integrity, do: safe_number(fn -> API.get_float("CORE_INTEGRITY") end, 100.0)

  defp beyond_saving? do
    safe(fn -> API.get_boolean("CORE_IMMINENT_FUSION") end) == true or
      core_integrity() <= @integrity_floor
  end

  # -- Progress bars -----------------------------------------------------------

  # Every bar gets a tick budget so a stage that never completes can't
  # strand the sequence. ProgressBar runs its own ticker-subscribed task,
  # so nothing here may raise — a crash would kill us and trip the guard.
  defp bar(label, config, current_fn, done_fn, limit) do
    UI.ProgressBar.wait(
      config: config,
      label: label,
      current_fn: current_fn,
      done_fn: with_limit(done_fn, limit)
    )
  end

  defp with_limit(done_fn, limit) do
    fn value ->
      n = Process.get(:bar_ticks, 0) + 1
      Process.put(:bar_ticks, n)

      cond do
        done_fn.(value) -> true
        n >= limit -> :abort
        true -> false
      end
    end
  end

  # -- Standing operators down, one at a time ---------------------------------

  defp stand_down(module, name) do
    UI.set_wait(
      name,
      "STAND DOWN",
      fn -> not any_subscribed?(module) end,
      fn -> unsubscribe_all(module) end
    )
  end

  # SecondaryFill runs one process per loop.
  defp unsubscribe_all(Op.SecondaryFill) do
    Enum.each(@loops, &PubSub.unsubscribe(Module.concat(Op.SecondaryFill, "L#{&1}"), :ticker))
  end

  defp unsubscribe_all(module), do: PubSub.unsubscribe(module, :ticker)

  defp any_subscribed?(Op.SecondaryFill) do
    subscribers = PubSub.subscribers(:ticker)

    Enum.any?(@loops, fn loop ->
      Process.whereis(Module.concat(Op.SecondaryFill, "L#{loop}")) in subscribers
    end)
  end

  defp any_subscribed?(module), do: Process.whereis(module) in PubSub.subscribers(:ticker)

  # -- Abort protection -------------------------------------------------------

  @doc """
  Spawn the abort guard: a detached process (NOT linked — a kill on the
  task must not take it with it) that scrams the plant if the calling
  process dies without standing the guard down.
  """
  def start_abort_guard(enabled \\ true)

  def start_abort_guard(false), do: nil

  def start_abort_guard(true) do
    task = self()

    spawn(fn ->
      ref = Process.monitor(task)

      receive do
        :stand_down ->
          :ok

        {:DOWN, ^ref, :process, ^task, :normal} ->
          :ok

        {:DOWN, ^ref, :process, ^task, _aborted} ->
          Logger.warning("[Meltdown] Aborted — inserting rods and scramming.")
          API.put("RODS_ALL_POS_ORDERED", 100)
          API.Misc.press_scram()
      end
    end)
  end

  defp stand_down_guard(nil), do: :ok
  defp stand_down_guard(pid), do: send(pid, :stand_down)

  # -- Helpers -----------------------------------------------------------------

  # The plant is being torn apart; individual reads and writes are
  # expected to start failing. Never let that end the show early.
  defp safe(fun) do
    fun.()
  rescue
    _ -> :err
  catch
    :exit, _ -> :err
  end

  defp safe_number(fun, default) do
    case safe(fun) do
      n when is_number(n) -> n / 1
      _ -> default
    end
  end

  defp fmt(value), do: :erlang.float_to_binary(value / 1, decimals: 1)
end
