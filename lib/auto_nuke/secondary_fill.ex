defmodule AutoNuke.SecondaryFill do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:loop, :pid, :speed]
    defstruct(
      loop: nil,
      pid: nil,
      speed: nil,
      last_fill_level: nil,
      last_ms: nil
    )
  end

  @log_prefix "[#{inspect(__MODULE__)}] "

  @tank_size 60000.0
  @target_percent 0.5
  @inlet_factor 2.0
  @max_speed_deviation 20.0

  def start_link(opts) do
    {loop, opts} = Keyword.pop!(opts, :loop)
    GenServer.start_link(__MODULE__, loop, opts)
  end

  @impl true
  def init(loop) when loop in 0..2 do
    pid = PIDControl.new(kp: 0.5, kd: 0.2, ki: 0.03)
    PubSub.subscribe(self(), :ticker)
    {:ok, %State{loop: loop, pid: pid, speed: get_speed(loop)}}
  end

  @impl true
  def handle_info({:tick, _old_ms, new_ms}, state) do
    fill_level = get_fill_percent(state.loop)

    cond do
      is_nil(state.last_fill_level) ->
        # First loop.
        {:noreply, %State{state | last_fill_level: fill_level, last_ms: new_ms}}

      state.last_fill_level == fill_level ->
        # Nothing changed.
        {:noreply, state}

      true ->
        # Fill level has changed.
        {:noreply, update_pump_speed(state, fill_level, new_ms)}
    end
  end

  defp update_pump_speed(state, fill_level, new_ms) do
    pid =
      state.pid
      |> update_time_factor(new_ms - state.last_ms)
      |> PIDControl.step(@target_percent, get_fill_percent(state.loop))

    IO.inspect(pid.output, label: "output")
    state = %State{state | pid: pid, last_fill_level: fill_level, last_ms: new_ms}

    new_speed =
      (get_outlet(state.loop) / @inlet_factor)
      |> adjust_pump_speed(pid.output)

    if new_speed != state.speed do
      Logger.info(@log_prefix <> "Setting loop #{state.loop} pump speed to #{new_speed}.")
      set_speed(state.loop, new_speed)
      %State{state | speed: new_speed}
    else
      state
    end
  end

  defp adjust_pump_speed(speed, output) do
    (speed + @max_speed_deviation * output)
    |> round()
    |> max(0)
    |> min(100)
  end

  defp get_fill_percent(loop) do
    AutoNuke.API.get_float("COOLANT_SEC_#{loop}_LIQUID_VOLUME") / @tank_size
  end

  defp get_outlet(loop) do
    AutoNuke.API.get_float("STEAM_GEN_#{loop}_OUTLET")
  end

  defp get_speed(loop) do
    AutoNuke.API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_#{loop}_ORDERED_SPEED")
  end

  defp set_speed(loop, value) do
    AutoNuke.API.put("COOLANT_SEC_CIRCULATION_PUMP_#{loop}_ORDERED_SPEED", value)
  end

  defp update_time_factor(pid, elapsed_ms) do
    %PIDControl{pid | config: Map.replace!(pid.config, :t, elapsed_ms / 1000.0)}
  end
end
