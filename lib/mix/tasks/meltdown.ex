defmodule Mix.Tasks.AutoNuke.Meltdown do
  @shortdoc "Deliberately destroy the plant (staged cascade)"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.API.SteamGen
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator, as: Op

  @moduledoc """
  Drives the plant into a cascading failure, in acts.

      mix auto_nuke.meltdown [pace %/game-min] [act limit in game-min]

  A sandbox toy: it exists to find out how the game behaves at its
  limits, and whether you can pull the plant back from the brink. It
  will wreck the reactor in your save.

  It doesn't just yank the rods. It takes the plant apart in the order a
  real cascade would go — secondary side first, so the steam plant tears
  itself up long before the core is in trouble:

    * **Act I — Sabotage.** Operators stood down, boron filtered out of
      the core, resistor banks off. Nothing looks wrong yet.
    * **Act II — Overpressure.** Feedwater to maximum, vents shut, then
      the steam outlets slowly choked. Steam generator pressure climbs
      with nowhere to go.
    * **Act III — Load rejection.** Turbines tripped and condenser
      vacuum killed at peak pressure, for the spike.
    * **Act IV — Heat sink.** The core pool is drained away.
    * **Act V — Prompt criticality.** Rods withdrawn and primary
      circulation throttled to nothing.
    * **Act VI — Aftermath.** Narrates core temperature and integrity to
      the end.

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

    act_1_sabotage(state)
    act_2_overpressure(state)
    act_3_load_rejection(state)
    act_4_heat_sink(state)
    act_5_prompt_criticality(state)
    act_6_aftermath(state)

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

  # -- Act I: sabotage the safeties -------------------------------------------

  @stood_down [
    {Op.ControlRods, "Control Rods Operator"},
    {Op.CoreTemp, "Core Temperature Operator"},
    {Op.PrimaryPumps, "Primary Pumps Operator"},
    {Op.SteamFlow, "Steam Flow Operator"},
    {Op.SecondaryFill, "Secondary Fill Operators"},
    {Op.BoronLevel, "Boron Level Operator"},
    {Op.ResistorBanks, "Resistor Banks Operator"},
    {Op.VacuumTank, "Vacuum Tank Operator"}
  ]

  defp act_1_sabotage(_state) do
    UI.console("ACT I — SABOTAGE")

    Enum.each(@stood_down, fn {module, name} ->
      UI.set_wait(
        name,
        "STAND DOWN",
        fn -> not any_subscribed?(module) end,
        fn -> unsubscribe_all(module) end
      )
    end)

    UI.set("Boron Filtering", "MAXIMUM")
    safe(fn -> API.put("CHEM_BORON_FILTER_ORDERED_SPEED", 100) end)

    UI.set("Resistor Banks", "OFF")
    safe(fn -> API.put("RESISTOR_BANKS_MAIN_SWITCH", false) end)

    UI.notice("The plant is now unsupervised.  Boron is coming out of the core.")
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

  defp act_2_overpressure(%{loops: []} = _state) do
    UI.console("ACT II — OVERPRESSURE")
    UI.notice("No live steam generators; skipping the secondary side.")
  end

  defp act_2_overpressure(state) do
    UI.console("ACT II — OVERPRESSURE")

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

  # -- Act III: reject the load ----------------------------------------------

  defp act_3_load_rejection(state) do
    UI.console("ACT III — LOAD REJECTION")

    UI.set("Turbines", "TRIP")
    safe(fn -> API.Misc.trip_turbines() end)

    UI.set("Condenser Vacuum Pump", "STOP")
    safe(fn -> API.VacuumPump.stop() end)

    UI.warn("Load rejected.  Steam has nowhere left to go.")

    # Let the spike develop and narrate it.
    settle(state, round(@ticks_per_minute * 2))
  end

  # -- Act IV: take away the heat sink ---------------------------------------

  defp act_4_heat_sink(state) do
    UI.console("ACT IV — HEAT SINK")

    UI.set("Core Pool", "DRAIN")
    safe(fn -> API.put("CORE_POOL_PUMP", "REMOVE") end)

    UI.notice("Draining the core pool.  External cooling is going away.")
    settle(state, round(@ticks_per_minute))
  end

  # -- Act V: prompt criticality ---------------------------------------------

  defp act_5_prompt_criticality(state) do
    UI.console("ACT V — PROMPT CRITICALITY")

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

  # -- Act VI: aftermath ------------------------------------------------------

  defp act_6_aftermath(state) do
    UI.console("ACT VI — AFTERMATH")
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
