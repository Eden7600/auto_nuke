defmodule Mix.Tasks.AutoNuke.Meltdown do
  @shortdoc "Deliberately destroy the plant (staged cascade)"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.API.SteamGen
  alias AutoNuke.Smoother
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator, as: Op

  @moduledoc """
  Drives the plant into a cascading failure, in acts.

      mix auto_nuke.meltdown [pace %/game-min] [act limit in game-min]

  A sandbox toy: it exists to find out how the game behaves at its
  limits, and whether you can pull the plant back from the brink. It
  will wreck the reactor in your save.

  It doesn't just yank the rods. It works the plant to death from the
  outside in, letting each stage settle before starting the next:

    * **Part I — Maximum output.** Resistor banks on, then the plant is
      asked for everything it can safely make: grid demand plus the full
      absorption capacity of the banks. The operators drive it up there
      and we wait for the power to plateau.
    * **Part II — Destroy the turbines.** Vacuum pump stopped and the
      condensate return valve opened, then we wait for the condenser
      vacuum to collapse. The turbines keep spinning into the rising
      backpressure.
    * **Part III — Overpressure.** Feedwater to maximum, vents shut,
      then the steam outlets slowly choked. Steam generator pressure
      climbs with nowhere to go.
    * **Part IV — Heat sink.** The core pool is drained away.
    * **Part V — Prompt criticality.** Boron filtered out, rods
      withdrawn, primary circulation throttled to nothing.
    * **Part VI — Aftermath.** Narrates core temperature and integrity
      to the end.

  Operators are stood down one at a time, each at the moment it becomes
  an obstacle — so the plant is running itself, hard, for as long as
  possible.

  **Aborting**: cancelling (`[x]` in the TUI) slams the rods home and
  presses SCRAM. It does not undo the valve work — that's yours to fix,
  if it's still fixable.
  """

  # Percent per in-game minute, for rods/valves/pumps:
  @default_pace 5.0
  # Give up on an act after this many in-game minutes:
  @default_act_limit 10.0

  @ticks_per_minute AutoNuke.Ticker.ticks_per_second() *
                      AutoNuke.Ticker.seconds_per_minute()

  @report_every 10
  @integrity_floor 1.0
  @loops 1..3

  # A steam generator counts as "live" above this pressure:
  @live_pressure 5.0

  # Output counts as plateaued when a full window of samples (one
  # in-game minute) opens and closes within this many MW of each other.
  @plateau_window @ticks_per_minute
  @plateau_threshold_mw 1.0

  # Vacuum (a 0-1 fraction) counts as gone below this:
  @vacuum_gone 0.5
  # Pressure milestones worth shouting about:
  @pressure_milestones [65, 70, 75, 80, 90, 100, 120]

  def run(args), do: run(args, [])

  def run([], opts), do: meltdown(@default_pace, @default_act_limit, opts)
  def run([pace], opts), do: meltdown(parse(pace, @default_pace), @default_act_limit, opts)

  def run([pace, limit], opts),
    do: meltdown(parse(pace, @default_pace), parse(limit, @default_act_limit), opts)

  defp parse("", default), do: default

  defp parse(str, _default) do
    case Float.parse(String.trim(str)) do
      {value, _} when value > 0 -> value
      _ -> Mix.raise("Expected a positive number.")
    end
  end

  def meltdown(pace, act_limit, opts \\ []) do
    UI.init()
    UI.log_to_file("startup.log")

    check_reactor_live()

    UI.console("☢ CASCADE SEQUENCE")
    UI.warn("Deliberately destroying the plant.  [x] aborts and SCRAMs.")

    guard = start_abort_guard(Keyword.get(opts, :guard, true))
    PubSub.subscribe(self(), :ticker)

    state = %{
      pace: pace,
      limit_ticks: round(act_limit * @ticks_per_minute),
      step: pace / @ticks_per_minute,
      loops: live_loops(),
      seen: MapSet.new()
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
      case safe(fn -> SteamGen.for_loop(loop) |> SteamGen.get_pressure() end) do
        p when is_number(p) -> p >= @live_pressure
        _ -> false
      end
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
        state

      _ ->
        UI.notice("Operators are now pushing the plant to its limit.")
        wait_for_plateau(state, target_mw, Smoother.new(@plateau_window), 0)
    end
  end

  defp wait_for_plateau(state, target_mw, history, n) do
    cond do
      n > state.limit_ticks * 3 ->
        UI.warn("Output never settled; pressing on anyway.")
        state

      plateau?(history) ->
        UI.success("Output has plateaued at #{fmt(total_generation_mw())} MW.")
        state

      true ->
        wait_tick()
        history = Smoother.add(history, total_generation_mw())

        if rem(n, @report_every) == 0 do
          UI.set(
            "Output",
            "#{fmt(total_generation_mw())} / #{fmt(target_mw)} MW  (climbing)"
          )
        end

        wait_for_plateau(state, target_mw, history, n + 1)
    end
  end

  @doc """
  Has output plateaued? True once a full window of samples opens and
  closes within `@plateau_threshold_mw` of each other — a partial window
  never counts, so a slow climb can't be mistaken for a plateau.
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

    UI.set("Condenser Vacuum Pump", "STOP")
    safe(fn -> API.VacuumPump.stop() end)

    UI.set("Condensate Return Valve", "OPEN")
    safe(fn -> API.Valves.set_open_percent(API.Valves.crv(), 100) end)

    UI.notice("Vacuum is on its own now.  The turbines keep spinning.")
    wait_for_vacuum_loss(state, 0)
  end

  defp wait_for_vacuum_loss(state, n) do
    vacuum = safe_number(fn -> API.VacuumPump.get_vacuum_level() end, 0.0)

    cond do
      vacuum <= @vacuum_gone ->
        UI.success("Condenser vacuum is gone (#{fmt(vacuum * 100)}%).")
        state

      n > state.limit_ticks * 3 ->
        UI.warn("Vacuum is holding at #{fmt(vacuum * 100)}%; pressing on.")
        state

      true ->
        wait_tick()

        state =
          if rem(n, @report_every) == 0 do
            UI.set("Condenser Vacuum", "#{fmt(vacuum * 100)}%")
            announce_once(state, {:vacuum, 95}, vacuum < 0.95, "Condenser vacuum is failing!")
          else
            state
          end

        wait_for_vacuum_loss(state, n + 1)
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

  # -- Act II: overpressure the steam generators ------------------------------

  defp part_3_overpressure(%{loops: []} = state) do
    UI.console("PART III — OVERPRESSURE")
    UI.notice("No live steam generators; skipping the secondary side.")
    state
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

    UI.set("Steam Outlets", "CHOKING #{state.pace}%/min")
    choke_loop(state, initial_openings(state.loops), 0)
  end

  defp initial_openings(loops) do
    Enum.map(loops, fn loop ->
      sg = SteamGen.for_loop(loop)

      {loop, sg,
       %{
         mscv: safe_percent(sg.mscv, 100.0),
         bypass: safe_percent(sg.bypass, 100.0)
       }}
    end)
  end

  defp safe_percent(valve, default) do
    case safe(fn -> API.Valves.get_open_percent(valve) end) do
      p when is_number(p) -> p / 1
      _ -> default
    end
  end

  defp choke_loop(state, openings, n) do
    closed? = Enum.all?(openings, fn {_l, _sg, o} -> o.mscv <= 0.0 and o.bypass <= 0.0 end)

    cond do
      closed? ->
        UI.success("Steam outlets fully shut.")
        state

      n > state.limit_ticks ->
        UI.warn("Act limit reached; moving on with outlets partly open.")
        state

      true ->
        wait_tick()

        openings =
          Enum.map(openings, fn {loop, sg, o} ->
            mscv = max(o.mscv - state.step, 0.0)
            bypass = max(o.bypass - state.step, 0.0)
            safe(fn -> API.Valves.set_open_percent(sg.mscv, Float.round(mscv, 1)) end)
            safe(fn -> API.Valves.set_open_percent(sg.bypass, Float.round(bypass, 1)) end)
            {loop, sg, %{mscv: mscv, bypass: bypass}}
          end)

        state = report_pressures(state, n)
        choke_loop(state, openings, n + 1)
    end
  end

  # -- Part IV: take away the heat sink ---------------------------------------

  defp part_4_heat_sink(state) do
    UI.console("PART IV — HEAT SINK")

    UI.set("Core Pool", "DRAIN")
    safe(fn -> API.put("CORE_POOL_PUMP", "REMOVE") end)

    UI.notice("Draining the core pool.  External cooling is going away.")
    settle(state, round(@ticks_per_minute))
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

    UI.set("Control Rods", "WITHDRAW #{state.pace}%/min")
    UI.set("Primary Pumps", "THROTTLE #{state.pace}%/min")

    rods = safe_number(fn -> API.get_float("RODS_POS_ACTUAL") end, 100.0)

    pumps =
      @loops
      |> Enum.map(&API.Pumps.primary/1)
      |> Enum.map(fn pump -> {pump, safe_number(fn -> API.Pumps.get_ordered_speed(pump) end, 0.0)} end)

    withdraw_loop(state, rods, pumps, 0)
  end

  defp withdraw_loop(state, rods, pumps, n) do
    done? = rods <= 0.0 and Enum.all?(pumps, fn {_p, speed} -> speed <= 0.0 end)

    cond do
      done? ->
        UI.success("Rods out, coolant stopped.")
        state

      beyond_saving?() ->
        UI.warn("The core is already past saving.")
        state

      n > state.limit_ticks * 2 ->
        UI.warn("Act limit reached.")
        state

      true ->
        wait_tick()

        rods = max(rods - state.step, 0.0)
        safe(fn -> API.put("RODS_ALL_POS_ORDERED", Float.round(rods, 1)) end)

        pumps =
          Enum.map(pumps, fn {pump, speed} ->
            speed = max(speed - state.step, 0.0)
            safe(fn -> API.Pumps.set_speed(pump, Float.round(speed, 1)) end)
            {pump, speed}
          end)

        state = report_core(state, n)
        withdraw_loop(state, rods, pumps, n + 1)
    end
  end

  # -- Part VI: aftermath ------------------------------------------------------

  defp part_6_aftermath(state) do
    UI.console("PART VI — AFTERMATH")
    UI.set("Meltdown", "IN PROGRESS")
    aftermath_loop(state, 0)
  end

  defp aftermath_loop(state, n) do
    cond do
      beyond_saving?() ->
        UI.warn("Core destroyed.")
        state

      n > state.limit_ticks * 6 ->
        UI.notice("Still holding on.  Leaving it to burn.")
        state

      true ->
        wait_tick()
        state = report_core(state, n)
        aftermath_loop(state, n + 1)
    end
  end

  # -- Narration ---------------------------------------------------------------

  defp settle(state, ticks) do
    Enum.reduce(0..ticks, state, fn n, acc ->
      wait_tick()
      acc |> report_pressures(n) |> report_core(n)
    end)
  end

  defp report_pressures(state, n) when rem(n, @report_every) != 0, do: state

  defp report_pressures(state, _n) do
    Enum.reduce(state.loops, state, fn loop, acc ->
      pressure = safe_number(fn -> SteamGen.for_loop(loop) |> SteamGen.get_pressure() end, 0.0)

      UI.set("Steam Gen 0#{loop}", "#{fmt(pressure)} bar")
      announce_milestones(acc, loop, pressure)
    end)
  end

  defp announce_milestones(state, loop, pressure) do
    @pressure_milestones
    |> Enum.filter(&(pressure >= &1))
    |> Enum.reduce(state, fn milestone, acc ->
      key = {:pressure, loop, milestone}

      if MapSet.member?(acc.seen, key) do
        acc
      else
        UI.warn("Steam generator 0#{loop} past #{milestone} bar!")
        %{acc | seen: MapSet.put(acc.seen, key)}
      end
    end)
  end

  defp report_core(state, n) when rem(n, @report_every) != 0, do: state

  defp report_core(state, _n) do
    temp = safe_number(fn -> API.get_float("CORE_TEMP") end, 0.0)
    integrity = safe_number(fn -> API.get_float("CORE_INTEGRITY") end, 100.0)
    rods = safe_number(fn -> API.get_float("RODS_POS_ACTUAL") end, 0.0)

    steam =
      cond do
        safe(fn -> API.get_boolean("CORE_HIGH_STEAM_PRESENT") end) == true -> "  ⚠ HIGH STEAM"
        safe(fn -> API.get_boolean("CORE_STEAM_PRESENT") end) == true -> "  ⚠ steam"
        true -> ""
      end

    UI.set("Core", "#{fmt(temp)}°C  rods #{fmt(rods)}%  integrity #{fmt(integrity)}%#{steam}")

    state
    |> announce_once({:core, :over_max}, temp > safe_number(fn -> API.get_float("CORE_TEMP_MAX") end, 550.0),
      "Core is over its maximum temperature!")
    |> announce_once({:core, :damaged}, integrity < 100.0, "Core integrity is falling!")
    |> announce_once({:core, :half}, integrity <= 50.0, "Core integrity below 50%!")
  end

  defp announce_once(state, _key, false, _message), do: state

  defp announce_once(state, key, true, message) do
    if MapSet.member?(state.seen, key) do
      state
    else
      UI.warn(message)
      %{state | seen: MapSet.put(state.seen, key)}
    end
  end

  defp beyond_saving? do
    safe(fn -> API.get_boolean("CORE_IMMINENT_FUSION") end) == true or
      safe_number(fn -> API.get_float("CORE_INTEGRITY") end, 100.0) <= @integrity_floor
  end

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

  defp wait_tick do
    receive do
      {:tick, _} -> :ok
    after
      # The game may be paused; keep the pane responsive either way.
      5_000 -> :ok
    end
  end
end
