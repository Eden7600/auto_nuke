defmodule AutoNuke.Operator.XenonGuard do
  @moduledoc """
  Xenon poisoning prevention.

  The game reports gross xenon production (`CORE_XENON_GENERATION`), but
  burn-off scales with core flux — so the signal that matters is the NET
  trend of `CORE_XENON_CUMULATIVE`. Measured live: a core factor of ~2.8
  balances a generation of ~35; at factor ~1 the same core drowned.

  Burning xenon needs reactivity headroom (withdrawing rods is what raises
  the flux), so this operator acts *early*:

    * **Burn**: xenon high and net-rising while rods still have travel →
      enable the resistor banks (excess power isn't counted against the
      score while they absorb it) and set a SteamFlow override above
      demand. Cleared once xenon is back down or clearly falling.
    * **Spiral alarm**: rods near zero, criticality non-positive, xenon
      still rising — burning is no longer possible; say so, loudly. The
      options at that point are SCRAM-and-wait or manual heroics.

  A user-set SteamFlow override is never overridden or cleared.
  """

  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Operator.{ResistorBanks, SteamFlow}
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Xenon cumulative levels (observed operating range ~60-80; the core
  # died climbing through ~78 with no margin left):
  @burn_threshold 70.0
  @burn_exit 62.0

  # Net-trend detection: slope across the sample window (~30s of samples).
  @trend_window 30
  @rising_slope 0.05

  # Burn only while the rods still have meaningful travel left:
  @min_rod_margin 10.0

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
    slope = Smoother.rate_of_change(history)
    rods = API.get_float("RODS_POS_ACTUAL")

    state = %State{state | history: history}

    state =
      cond do
        spiral?(rods, slope) -> spiral_alarm(state, xenon, t)
        not state.burning and should_burn?(xenon, slope, rods) -> start_burn(state, xenon)
        state.burning and should_stop?(xenon, slope) -> stop_burn(state, xenon)
        state.burning -> maybe_renew_override(state)
        true -> state
      end

    {:noreply, state}
  end

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

  defp should_burn?(xenon, slope, rods) do
    xenon > @burn_threshold and slope > @rising_slope and rods > @min_rod_margin
  end

  defp should_stop?(xenon, slope) do
    xenon < @burn_exit or (xenon < @burn_threshold and slope < -@rising_slope)
  end

  defp start_burn(%State{} = state, xenon) do
    Logger.warning(
      @log_prefix <>
        "Xenon at #{Float.round(xenon, 1)} and rising — starting burn-off procedure."
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

  defp spiral?(rods, slope) do
    rods < @min_rod_margin and slope > 0 and
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
