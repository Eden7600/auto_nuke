defmodule AutoNuke.Operator.XenonGuard do
  @moduledoc """
  Xenon poisoning prevention.

  The game reports gross xenon production (`CORE_XENON_GENERATION`), which
  stays high on a perfectly healthy core because burn-off scales with flux
  and cancels it. The signal that matters is the NET trend of
  `CORE_XENON_CUMULATIVE`.

  Absolute xenon levels are deliberately NOT used as triggers: what counts
  as "high" depends on the plant and its power level, and guessing wrong
  either cries wolf or misses the problem. Instead this operator watches
  the thing that actually hurts — **reactivity margin being spent to
  compensate for rising xenon**. `BoronLevel` keeps the rods in a 33-66%
  band; rods driven well below that while xenon climbs means the
  compensation loop is losing.

    * **Burn**: xenon net-rising while rod margin is low but not gone →
      enable the resistor banks (excess power isn't counted against the
      score while they absorb it) and set a SteamFlow override above
      demand. Cleared once xenon falls and margin recovers.
    * **Spiral alarm**: margin gone (rods bottomed, boron nearly gone) with
      the reaction dying and xenon still rising — burning is no longer
      possible; say so, loudly.

  A user-set SteamFlow override is never overridden or cleared.
  """

  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Operator.{ResistorBanks, SteamFlow}
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Net-trend detection: total change across the sample window (~30s).
  # A stable core was measured drifting ~0.03 over that span, so this sits
  # an order of magnitude above the noise floor. Provisional: it wants
  # confirming against a real poisoning event.
  @trend_window 30
  @rising_slope 0.5

  # Rod margin (percent inserted). BoronLevel aims to hold 33-66%, so
  # being pushed below @margin_low means we're losing ground...
  @margin_low 25.0
  # ...and this much recovery means we've won it back.
  @margin_ok 35.0
  # Below this there is nothing left to withdraw — burning is impossible.
  @min_rod_margin 10.0
  # With rods bottomed, boron this low means no chemical margin either.
  @min_boron 100.0

  # Burn power: this multiple of demand (resistors soak the surplus).
  @burn_power_ratio 1.10

  # Re-issue the spiral alarm at most every N ticks (~2 game-minutes):
  @spiral_alarm_interval 120

  defmodule State do
    defstruct history: nil, burning: false, our_override: false, next_spiral_alarm: 0
  end

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def burning?(pid \\ __MODULE__), do: GenServer.call(pid, :burning?)

  @impl true
  def init(nil) do
    PubSub.subscribe(self(), :ticker)
    xenon = API.get_float("CORE_XENON_CUMULATIVE")
    Logger.info(@log_prefix <> "Started with xenon at #{Float.round(xenon, 1)}.")
    {:ok, %State{history: Smoother.new(@trend_window) |> Smoother.add(xenon)}}
  end

  @impl true
  def handle_call(:burning?, _from, %State{} = state) do
    {:reply, state.burning, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, t}, %State{} = state) do
    xenon = API.get_float("CORE_XENON_CUMULATIVE")
    history = Smoother.add(state.history, xenon)
    rods = API.get_float("RODS_POS_ACTUAL")

    state = %State{state | history: history}

    # `rate_of_change` extrapolates from a partial window, so a small
    # wiggle during warmup reads as a steep slope. Wait for a full window
    # before trusting the trend.
    state =
      if trend_ready?(history) do
        slope = Smoother.rate_of_change(history)

        cond do
          spiral?(rods, slope) -> spiral_alarm(state, xenon, t)
          not state.burning and should_burn?(slope, rods) -> start_burn(state, xenon, rods)
          state.burning and should_stop?(slope, rods) -> stop_burn(state, xenon)
          state.burning -> maybe_renew_override(state)
          true -> state
        end
      else
        state
      end

    {:noreply, state}
  end

  defp trend_ready?(%Smoother{size: size, max: max}), do: size >= max

  # Our override carries an hourly expiry as a failsafe (it clears itself
  # if this operator dies mid-burn); while alive and burning, renew it.
  defp maybe_renew_override(%State{our_override: true} = state) do
    case steam_flow_override() do
      :none ->
        burn_mw = API.Power.get_demand_mw() * @burn_power_ratio
        SteamFlow.set_target_override_mw(burn_mw, :next_hour)
        state

      _ ->
        state
    end
  end

  defp maybe_renew_override(state), do: state

  # -- Burn procedure ---------------------------------------------------------

  # Rising xenon that we're paying for in rod margin, while enough margin
  # remains to actually raise flux.
  defp should_burn?(slope, rods) do
    slope > @rising_slope and rods < @margin_low and rods > @min_rod_margin
  end

  # Stop once xenon is genuinely falling, or margin has recovered.
  defp should_stop?(slope, rods) do
    (slope < -@rising_slope and rods > @margin_low) or rods > @margin_ok
  end

  defp start_burn(%State{} = state, xenon, rods) do
    Logger.warning(
      @log_prefix <>
        "Xenon at #{Float.round(xenon, 1)} and rising with rods down to " <>
        "#{Float.round(rods, 1)}% — starting burn-off procedure."
    )

    ResistorBanks.enable_banks()

    our_override =
      case steam_flow_override() do
        :absent ->
          Logger.warning(@log_prefix <> "SteamFlow not running — burning with resistors only.")
          false

        {:set, _} ->
          Logger.warning(@log_prefix <> "A power override is already set — not touching it.")
          false

        :none ->
          burn_mw = API.Power.get_demand_mw() * @burn_power_ratio
          SteamFlow.set_target_override_mw(burn_mw, :next_hour)
          Logger.warning(@log_prefix <> "Power override set to #{Float.round(burn_mw, 1)} MW.")
          true
      end

    %State{state | burning: true, our_override: our_override}
  end

  defp stop_burn(%State{} = state, xenon) do
    Logger.notice(
      @log_prefix <> "Xenon down to #{Float.round(xenon, 1)} — ending burn-off procedure."
    )

    if state.our_override do
      case steam_flow_override() do
        {:set, _} -> SteamFlow.clear_target_override()
        _ -> :ok
      end
    end

    ResistorBanks.disable_banks()
    %State{state | burning: false, our_override: false}
  end

  # Keep our override alive while burning (it expires hourly on its own if
  # this operator dies — deliberate failsafe).
  defp steam_flow_override do
    try do
      case GenServer.call(SteamFlow, :get_override, 250) do
        nil -> :none
        override -> {:set, override}
      end
    catch
      :exit, _ -> :absent
    end
  end

  # -- Spiral alarm -----------------------------------------------------------

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
        "and the reaction dying. Burn-off is no longer possible — " <>
        "SCRAM and wait out the decay, or shed load immediately."
    )

    %State{state | next_spiral_alarm: t + @spiral_alarm_interval}
  end

  defp spiral_alarm(state, _xenon, _t), do: state
end
