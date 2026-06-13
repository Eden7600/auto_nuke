defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:target, :axis]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # I'm told that <10% is dangerous and >50% is useless.
  # Also, there's the "keep pumps below 50%" objective.
  @speeds 10..49
  def pump_speed_range, do: @speeds
  @speed_span (@speeds.last - @speeds.first) / 2

  # Used by the `startup` task to know what speed to set on cold start.
  def min_speed, do: @speeds.first

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
    target = state.target

    case ControlAxis.step(state.axis, target, temp) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing pump speeds from #{old} to #{new}.")
        set_pump_speeds(new)
        {axis, new}

      {:unchanged, axis, old} ->
        {axis, old}
    end
    |> then(fn {axis, speed} ->
      PubSub.publish(:core_temp, {:core_temp, target, speed})
      {:noreply, %State{state | axis: axis}}
    end)
  end

  @core API.Vessels.core_vessel()
  @pumps API.Pumps.all_primary()

  defp get_average_pump_speed do
    @pumps
    |> Enum.map(&API.Pumps.get_ordered_speed/1)
    |> Enum.reject(&(&1 not in @speeds))
    |> then(fn
      # If all pumps are out of range, assume minimum.
      [] -> [@speeds.first]
      speeds when is_list(speeds) -> speeds
    end)
    |> Statistex.average()
  end

  defp set_pump_speeds(speed) when speed in @speeds do
    @pumps
    |> Enum.each(&API.Pumps.set_speed(&1, speed))
  end

  defp get_temperature(), do: API.Vessels.get_temperature(@core)

  defp axis_to_speed(output), do: round((output + 1.0) * @speed_span + @speeds.first)
  defp speed_to_axis(speed), do: (speed - @speeds.first) / @speed_span - 1.0

  # If speed is low, assume it's because our old target was too high.
  defp get_initial_target(speed, temp) when speed == @speeds.first, do: temp + 10
  # If speed is high, assume it's because our old target was too low.
  defp get_initial_target(speed, temp) when speed == @speeds.last, do: temp - 10
  defp get_initial_target(_, temp), do: temp
end
