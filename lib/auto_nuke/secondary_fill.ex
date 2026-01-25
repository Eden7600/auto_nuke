defmodule AutoNuke.SecondaryFill do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:loop, :pid, :speed, :fill_level]
    defstruct(@enforce_keys)
  end

  @log_prefix "[#{inspect(__MODULE__)}] "
  @loop_every 100

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
    pid = PIDControl.new(kp: 1, kd: 0, ki: 0)

    state = %State{
      loop: loop,
      pid: pid,
      speed: get_speed(loop),
      fill_level: get_fill_percent(loop)
    }

    {:ok, state, {:continue, :loop}}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      get_fill_percent(state.loop)
      |> update_fill_level(state)

    {:noreply, state, {:continue, :loop}}
  end

  @impl true
  def handle_continue(:loop, state) do
    Process.send_after(self(), :loop, @loop_every)
    {:noreply, state}
  end

  defp update_fill_level(level, %State{fill_level: level} = state) do
    # Nothing changed.
    state
  end

  defp update_fill_level(new_level, %State{} = state) do
    pid = state.pid |> PIDControl.step(@target_percent, new_level)

    IO.inspect(pid.output, label: "output")
    state = %State{state | pid: pid, fill_level: new_level}

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
end
