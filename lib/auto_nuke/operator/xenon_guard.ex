defmodule AutoNuke.Operator.XenonGuard do
  @moduledoc """
  Xenon poisoning watchdog.

  How xenon actually works in Nucleares (community-sourced, not like real
  life): iodine converts to xenon exactly 6 in-game hours after it is
  produced, and that xenon disappears about 9 hours after forming. Today's
  xenon is yesterday's iodine — nothing done to the core now changes the
  wave that is already scheduled. In particular, burning xenon with extra
  power is a trap: it burns a little now while raising iodine production
  instantly, seeding a bigger wave 6 hours later. (This operator used to
  run exactly that burn procedure; it made things worse.)

  What controls xenon is iodine *production*: keep
  `CORE_IODINE_GENERATION` under ~3.5 and the waves stay manageable. High
  boron suppresses iodine production at the same power output — that's
  `BoronLevel`'s boron-heavy strategy (rods mostly out, boron carrying the
  absorption), and the boron doubles as the reserve that gets filtered
  away to keep the reaction alive while a wave passes.

  So this operator watches and warns; riding out the wave is BoronLevel's
  job:

    * **Iodine watch**: production over 3.5 → warn with the expected wave
      arrival (+6 game hours); all-clear once it settles back down.
    * **Xenon watch**: cumulative over 20 is bad on any plant → warn that
      a wave is in progress (it clears on its own within ~9 game hours).
    * **Spiral alarm**: rods bottomed, boron reserve gone, reaction dying,
      xenon still rising — nothing left to ride on; say so, loudly.
  """

  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Net-trend detection: total change across the sample window (~30s).
  # A stable core was measured drifting ~0.03 over that span, so this sits
  # an order of magnitude above the noise floor. Provisional: it wants
  # confirming against a real poisoning event.
  @trend_window 30
  @rising_slope 0.5

  # Cumulative xenon above this is bad on any plant; recovered once it is
  # back below @xenon_ok (hysteresis so the watch doesn't flap).
  @xenon_high 20.0
  @xenon_ok 15.0

  # Iodine production above this schedules an unmanageable xenon wave for
  # 6 game-hours out; settled once back below @iodine_ok. Averaged over a
  # window because the readout wobbles tick to tick.
  @iodine_high 3.5
  @iodine_ok 3.0
  @iodine_window 10

  # Iodine turns into xenon this long after being produced.
  @wave_delay_min 6 * 60

  # Below this there is no rod travel left to give.
  @min_rod_margin 10.0
  # With rods bottomed, boron this low means no chemical reserve either.
  @min_boron 100.0

  # Re-issue the spiral alarm at most every N ticks (~2 game-minutes):
  @spiral_alarm_interval 120

  defmodule State do
    defstruct xenon_history: nil,
              iodine_history: nil,
              iodine_high: false,
              wave: false,
              next_spiral_alarm: 0
  end

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @doc "Is a xenon wave (cumulative over the ceiling) in progress?"
  def wave?(pid \\ __MODULE__), do: GenServer.call(pid, :wave?)

  @doc "Cumulative xenon above this is bad on any plant."
  def xenon_ceiling, do: @xenon_high

  @doc "Iodine production above this makes the next wave unmanageable."
  def iodine_limit, do: @iodine_high

  @impl true
  def init(nil) do
    PubSub.subscribe(self(), :ticker)
    xenon = API.get_float("CORE_XENON_CUMULATIVE")
    iodine_gen = API.get_float("CORE_IODINE_GENERATION")

    Logger.info(
      @log_prefix <>
        "Started with xenon at #{Float.round(xenon, 1)}, " <>
        "iodine production #{Float.round(iodine_gen, 2)}."
    )

    {:ok,
     %State{
       xenon_history: Smoother.new(@trend_window) |> Smoother.add(xenon),
       iodine_history: Smoother.new(@iodine_window) |> Smoother.add(iodine_gen)
     }}
  end

  @impl true
  def handle_call(:wave?, _from, %State{} = state) do
    {:reply, state.wave, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, t}, %State{} = state) do
    xenon = API.get_float("CORE_XENON_CUMULATIVE")
    iodine_gen = API.get_float("CORE_IODINE_GENERATION")
    rods = API.get_float("RODS_POS_ACTUAL")

    state = %State{
      state
      | xenon_history: Smoother.add(state.xenon_history, xenon),
        iodine_history: Smoother.add(state.iodine_history, iodine_gen)
    }

    state
    |> check_spiral(xenon, rods, t)
    |> check_wave(xenon)
    |> check_iodine()
    |> then(&{:noreply, &1})
  end

  defp trend_ready?(%Smoother{size: size, max: max}), do: size >= max

  # -- Spiral alarm -----------------------------------------------------------

  # `rate_of_change` extrapolates from a partial window, so a small wiggle
  # during warmup reads as a steep slope. Wait for a full window before
  # trusting the trend.
  defp check_spiral(%State{xenon_history: history} = state, xenon, rods, t) do
    if trend_ready?(history) and spiral?(rods, Smoother.rate_of_change(history)) do
      spiral_alarm(state, xenon, t)
    else
      state
    end
  end

  # No rods left to withdraw, no boron left to filter, reaction dying, and
  # xenon still climbing.
  defp spiral?(rods, slope) do
    rods < @min_rod_margin and slope > 0 and
      API.get_float("CHEM_BORON_PPM") < @min_boron and
      API.get_float("CORE_STATE_CRITICALITY") <= 0
  end

  defp spiral_alarm(%State{next_spiral_alarm: next} = state, xenon, t) when t >= next do
    Logger.error(
      @log_prefix <>
        "XENON SPIRAL: xenon #{Float.round(xenon, 1)} rising with no rod margin left " <>
        "and the reaction dying. No reserve left to ride on — " <>
        "SCRAM and wait out the decay, or shed load immediately."
    )

    %State{state | next_spiral_alarm: t + @spiral_alarm_interval}
  end

  defp spiral_alarm(state, _xenon, _t), do: state

  # -- Xenon wave watch -------------------------------------------------------

  defp check_wave(%State{wave: false} = state, xenon) when xenon > @xenon_high do
    Logger.warning(
      @log_prefix <>
        "Xenon at #{Float.round(xenon, 1)} — over the #{@xenon_high} ceiling. " <>
        "A wave is in progress; it clears on its own within ~9 game hours. " <>
        "Riding it out on rod travel and boron reserve."
    )

    %State{state | wave: true}
  end

  defp check_wave(%State{wave: true} = state, xenon) when xenon < @xenon_ok do
    Logger.notice(@log_prefix <> "Xenon down to #{Float.round(xenon, 1)} — wave passed.")
    %State{state | wave: false}
  end

  defp check_wave(state, _xenon), do: state

  # -- Iodine production watch ------------------------------------------------

  # Averaged, and only once the window is full — a single-tick spike
  # shouldn't cry wolf.
  defp check_iodine(%State{iodine_history: history} = state) do
    if trend_ready?(history) do
      check_iodine(state, Smoother.average(history))
    else
      state
    end
  end

  defp check_iodine(%State{iodine_high: false} = state, avg) when avg > @iodine_high do
    eta = AutoNuke.Time.get_current_time() + @wave_delay_min

    Logger.warning(
      @log_prefix <>
        "Iodine production at #{Float.round(avg, 2)} — over the #{@iodine_high} line. " <>
        "This schedules a xenon wave for ~#{AutoNuke.Time.timestamp_to_string(eta)}. " <>
        "More boron (or less power swing) brings it down."
    )

    %State{state | iodine_high: true}
  end

  defp check_iodine(%State{iodine_high: true} = state, avg) when avg < @iodine_ok do
    Logger.notice(
      @log_prefix <> "Iodine production down to #{Float.round(avg, 2)} — back in range."
    )

    %State{state | iodine_high: false}
  end

  defp check_iodine(state, _avg), do: state
end
