defmodule AutoNuke.Operator.CondenserCooling do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:last_temp, :probe_timer]
    defstruct(
      last_temp: nil,
      probe_timer: nil,
      last_direction: :stable,
      boost_mode: nil,
      fast_probe: false
    )
  end

  alias AutoNuke.API
  alias AutoNuke.Time, as: ANTime

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @condenser API.Vessels.condenser()
  @pump API.Pumps.condenser_cooling()

  # Range of allowed speeds.
  @speeds 10..100
  def speed_range, do: @speeds
  # Wait 30 in-game minutes after a violation to begin probing lower speeds:
  @wait_after_violation 30 * AutoNuke.Ticker.seconds_per_minute()
  # While probing, wait 10 in-game minutes per 1% speed drop:
  @wait_while_slow_probing 10 * AutoNuke.Ticker.seconds_per_minute()
  # While fast-probing, wait 1 in-game minute per 1% speed drop:
  @wait_while_fast_probing 1 * AutoNuke.Ticker.seconds_per_minute()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def enable_boost_mode(expiry \\ :next_hour, pid \\ __MODULE__) do
    GenServer.call(pid, {:boost_mode, ANTime.parse_expiry(expiry)})
  end

  def get_boost_mode(pid \\ __MODULE__) do
    GenServer.call(pid, :get_boost_mode)
  end

  def disable_boost_mode(pid \\ __MODULE__) do
    GenServer.call(pid, {:boost_mode, nil})
  end

  @impl true
  def init(_) do
    temp = get_temperature()
    speed = get_pump_speed()

    state = %State{
      last_temp: temp,
      probe_timer: @wait_while_slow_probing
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with temperature #{temp}°C, pump at #{speed}%.")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_boost_mode, _from, %State{boost_mode: boost} = state) do
    {:reply, boost, state}
  end

  @impl true
  def handle_call({:boost_mode, nil}, _from, %State{} = state) do
    if state.boost_mode do
      Logger.notice(@log_prefix <> "Boost mode disabled.")
      {:reply, :ok, %State{state | boost_mode: nil} |> enable_fast_probe()}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:boost_mode, expiry}, _from, %State{} = state) do
    desc =
      case expiry do
        :never -> "enabled, no expiry"
        ts -> "enabled until #{ANTime.timestamp_to_string(ts)}"
      end

    Logger.notice(@log_prefix <> "Boost mode #{desc}.")
    set_pump_speed(@speeds.last)
    {:reply, :ok, %State{state | boost_mode: expiry}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state = state |> maybe_expire_boost_mode()
    new_temp = get_temperature()
    old_temp = state.last_temp
    threshold = get_violation_threshold()

    status =
      cond do
        new_temp >= threshold -> :above
        new_temp < threshold -> :below
      end

    direction =
      cond do
        abs(new_temp - old_temp) < 0.01 -> :stable
        new_temp > old_temp -> :increasing
        new_temp < old_temp -> :decreasing
      end

    # We track both the current direction and the previous direction,
    # to avoid momentary reading glitches from throwing us off.

    case {status, direction, state.last_direction} do
      # === Above threshold: ===
      # - Steadily increasing: Backoff by 3%.
      {:above, :increasing, :increasing} -> backoff(state, 3, new_temp)
      # - Decreasing: Good, but hold off on probing until we're safe.
      {:above, :decreasing, _} -> probe_wait(state, :violation)
      {:above, _, :decreasing} -> probe_wait(state, :violation)
      # - Any other situation: Let's back off to get it below the threshold.
      {:above, _, _} -> backoff(state, 1, new_temp)
      # 
      # === Below threshold: ===
      # - Steadily increasing: Hold off on probing.
      {:below, :increasing, :increasing} -> probe_wait(state, :normal)
      # - Recent increase: Skip the timer for this tick.
      {:below, :increasing, _} -> probe_skip(state)
      {:below, _, :increasing} -> probe_skip(state)
      # - No recent increases: Begin probing downwards.
      {:below, _, _} -> maybe_probe(state, new_temp)
    end
    |> then(fn %State{} = new_state ->
      {:noreply, %State{new_state | last_temp: new_temp, last_direction: direction}}
    end)
  end

  defp maybe_expire_boost_mode(%State{boost_mode: nil} = state), do: state
  defp maybe_expire_boost_mode(%State{boost_mode: :never} = state), do: state

  defp maybe_expire_boost_mode(%State{boost_mode: ts} = state) when is_integer(ts) do
    if ANTime.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Boost mode has expired.")
      %State{state | boost_mode: nil} |> enable_fast_probe()
    else
      state
    end
  end

  defp enable_fast_probe(%State{fast_probe: true} = state), do: state

  defp enable_fast_probe(%State{fast_probe: false, probe_timer: timer} = state) do
    %State{state | fast_probe: true, probe_timer: min(timer, @wait_while_fast_probing)}
  end

  defp backoff(%State{} = state, amount, temp) do
    old = get_pump_speed()
    new = if state.boost_mode, do: @speeds.last, else: (old + amount) |> min(@speeds.last)
    vio = fn -> @log_prefix <> "Temperature violation at #{Float.round(temp, 1)}°C" end

    if new == old do
      Logger.warning(vio.() <> ", but pump is maxed!")
      steam_flow_control(:backoff)
    else
      Logger.info(vio.() <> ", backing off from #{old}% to #{new}%.")
      steam_flow_control(:hold)
    end

    set_pump_speed(new)
    %State{state | probe_timer: @wait_after_violation, fast_probe: false}
  end

  defp probe_wait(%State{fast_probe: fast} = state, type) do
    wait =
      case type do
        :violation -> @wait_after_violation
        :normal -> probe_wait_ticks(fast)
      end

    steam_flow_control(:hold)
    %State{state | probe_timer: max(state.probe_timer, wait)}
  end

  defp probe_wait_ticks(true), do: @wait_while_fast_probing
  defp probe_wait_ticks(false), do: @wait_while_slow_probing

  defp maybe_probe(%State{boost_mode: boost} = state, _) when not is_nil(boost) do
    steam_flow_control(:resume)
    state
  end

  defp maybe_probe(%State{probe_timer: timer} = state, _) when timer > 0 do
    steam_flow_control(:resume)
    %State{state | probe_timer: timer - 1}
  end

  defp maybe_probe(%State{} = state, temp) do
    steam_flow_control(:resume)
    new = get_pump_speed() - 1

    if new in @speeds do
      Logger.info(@log_prefix <> "Steady at #{Float.round(temp, 1)}°C, trying #{new}%.")
      set_pump_speed(new)
      %State{state | probe_timer: probe_wait_ticks(state.fast_probe)}
    else
      # We're at the lowest allowed setting.
      # No point in ever probing any lower!
      # Just set the timer insanely high.
      # Unless we see a violation, we don't care.
      %State{state | probe_timer: 999_999_999}
    end
  end

  defp probe_skip(state) do
    steam_flow_control(:resume)
    state
  end

  defp steam_flow_control(action) do
    PubSub.publish(:steam_flow_control, {:steam_flow_control, action})
  end

  # As total steam output increases, we need to allow more leeway.
  defp get_violation_threshold do
    over_ambient = 5 + get_total_steam() / 50

    (over_ambient + get_ambient())
    # Never exceed 40°C, though.
    |> min(40)
  end

  @steam_gens API.SteamGen.all()
  defp get_total_steam do
    @steam_gens
    |> Enum.map(&API.SteamGen.get_outlet/1)
    |> Enum.sum()
  end

  defp get_temperature, do: API.Vessels.get_temperature(@condenser)
  defp get_ambient, do: API.Misc.ambient_temperature()

  defp get_pump_speed, do: API.Pumps.get_actual_speed(@pump) |> round()
  defp set_pump_speed(v), do: API.Pumps.set_speed(@pump, v)
end
