defmodule AutoNuke.Ticker do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:ms, :last_time]
    defstruct(@enforce_keys)
  end

  @log_prefix "[#{inspect(__MODULE__)}] "
  @ms_per_timestamp 10000

  @loop_every 100
  @slew_factor 0.1

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    ts = calibrate()

    state = %State{
      ms: ts * @ms_per_timestamp,
      last_time: DateTime.utc_now()
    }

    Logger.info(@log_prefix <> "Started with timestamp #{state.ms}.")
    {:ok, state, {:continue, :loop}}
  end

  @impl true
  def handle_continue(:loop, state) do
    Process.send_after(self(), :loop, @loop_every)
    {:noreply, state}
  end

  @impl true
  def handle_info(:loop, old_state) do
    sim_speed = get_sim_speed()
    new_state = update_state(old_state, sim_speed)
    {:noreply, new_state, {:continue, :loop}}
  end

  defp update_state(state, 0), do: %State{state | last_time: DateTime.utc_now()}

  defp update_state(state, sim_speed) when sim_speed > 0 do
    timestamp = get_timestamp()
    now = DateTime.utc_now()
    elapsed = DateTime.diff(now, state.last_time, :millisecond) * sim_speed

    new_state =
      %State{state | ms: state.ms + elapsed, last_time: now}
      |> apply_correction(timestamp, elapsed)

    PubSub.publish(:ticker, {:tick, state.ms, new_state.ms})
    new_state
  end

  defp apply_correction(%State{} = state, game_ts, elapsed) do
    my_ts = div(state.ms, @ms_per_timestamp)

    cond do
      my_ts == game_ts ->
        state

      my_ts > game_ts ->
        c = round(-elapsed * @slew_factor)
        Logger.debug("Running too fast, applying correction #{c}.")
        %State{state | ms: state.ms + c}

      my_ts < game_ts ->
        c = round(elapsed * @slew_factor)
        Logger.debug("Running too slow, applying correction #{c}.")
        %State{state | ms: state.ms + c}
    end
  end

  defp get_timestamp, do: AutoNuke.API.get_integer("TIME_STAMP")
  defp get_sim_speed, do: AutoNuke.API.get_integer("GAME_SIM_SPEED")

  defp calibrate do
    Logger.debug(@log_prefix <> "Calibrating ...")
    get_timestamp() |> calibrate_loop()
  end

  defp calibrate_loop(old_stamp) do
    case get_timestamp() do
      ^old_stamp -> calibrate_loop(old_stamp)
      new_stamp -> new_stamp
    end
  end
end
