defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:target, :axis]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] "

  # We'll use the raw indices here for convenience.
  @loops 0..2
  # I'm told that <10% is dangerous and >50% is useless.
  # Also, there's the "keep pumps below 50%" objective.
  @speeds 10..49
  @speed_span (@speeds.last - @speeds.first) / 2

  def start_link(opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, target, opts)
  end

  def set_target(target, pid \\ __MODULE__) do
    GenServer.cast(pid, {:target, target})
  end

  @impl true
  def init(target) when is_number(target) or is_nil(target) do
    temp = get_temperature()
    speed = get_average_pump_speed()
    target = target || get_initial_target(speed, temp)

    axis =
      ControlAxis.new(
        kp: -0.01,
        ki: -0.001,
        deadzone: 0.5,
        to_value_fn: &axis_to_speed/1,
        offset: speed |> speed_to_axis(),
        initial_value: speed
      )

    state =
      %State{
        target: target,
        axis: axis
      }

    PubSub.subscribe(self(), :ticker)

    Logger.info(
      @log_prefix <> "Started with temperature #{temp}°C, target #{target}°C, pumps at #{speed}."
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:target, t}, %State{} = state) do
    Logger.info(
      @log_prefix <> "Core temperature target changed from #{state.target}°C to #{t}°C."
    )

    {:noreply, %State{state | target: t}}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    temp = get_temperature()

    case ControlAxis.step(state.axis, state.target, temp) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing pump speeds from #{old} to #{new}.")
        set_pump_speeds(new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis}}
    end)
  end

  defp get_average_pump_speed do
    @loops
    |> Enum.map(&get_pump_speed/1)
    |> Enum.reject(&(&1 < @speeds.first))
    |> then(fn
      # Will average out to mid-speed.
      # Seems like a reasonable place to start if we can't find any usable speeds.
      [] -> [@speeds.first, @speeds.last]
      speeds when is_list(speeds) -> speeds
    end)
    |> Statistex.average()
  end

  defp set_pump_speeds(speed) when speed in @speeds do
    @loops |> Enum.each(&set_pump_speed(&1, speed))
  end

  defp get_temperature(), do: API.get_float("CORE_TEMP")

  defp get_pump_speed(n), do: API.get_float("COOLANT_CORE_CIRCULATION_PUMP_#{n}_SPEED")
  defp set_pump_speed(n, v), do: API.put("COOLANT_CORE_CIRCULATION_PUMP_#{n}_ORDERED_SPEED", v)

  defp axis_to_speed(output), do: round((output + 1.0) * @speed_span + @speeds.first)
  defp speed_to_axis(speed), do: (speed - @speeds.first) / @speed_span - 1.0

  # If speed is low, assume it's because our old target was too high.
  defp get_initial_target(speed, temp) when speed == @speeds.first, do: temp + 10
  # If speed is high, assume it's because our old target was too low.
  defp get_initial_target(speed, temp) when speed == @speeds.last, do: temp - 10
  defp get_initial_target(_, temp), do: temp
end
