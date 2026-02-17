defmodule AutoNuke.Operator.SecondaryFill do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:loop, :axis]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] "

  @tank_size 60000.0

  # Use 50% fill level at 60 bars of pressure.
  @reference_pressure 60
  @reference_level 0.5
  # For every 10 bars deviation, adjust fill level by 5%.
  @adjust_pressure 10
  @adjust_level 0.05

  def start_link(opts) do
    {loop, opts} = Keyword.pop!(opts, :loop)
    GenServer.start_link(__MODULE__, loop, opts)
  end

  @impl true
  def init(loop) when loop in 1..3 do
    speed = get_speed(loop)

    axis =
      ControlAxis.new(
        kp: 1,
        ki: 0.1,
        deadzone: 0.01,
        to_value_fn: &axis_to_speed/1,
        offset: speed |> speed_to_axis(),
        initial_value: speed
      )

    state = %State{
      loop: loop,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)

    fill_level = get_fill_percent(loop) |> Float.round(2)
    Logger.info(@log_prefix <> "Started with fill level of #{fill_level * 100}%.")

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{loop: loop} = state) do
    case ControlAxis.step(state.axis, get_target_percent(loop), get_fill_percent(loop)) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing loop #{loop} speed from #{old} to #{new}.")
        set_speed(loop, new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis}}
    end)
  end

  defp get_fill_percent(loop) do
    AutoNuke.API.get_float("COOLANT_SEC_#{loop - 1}_LIQUID_VOLUME") / @tank_size
  end

  defp get_target_percent(loop) do
    pressure = AutoNuke.API.get_float("COOLANT_SEC_#{loop - 1}_PRESSURE")

    # Both of these are positive if pressure is low, negative if high.
    delta_p = @reference_pressure - pressure
    adjust = @adjust_level * (delta_p / @adjust_pressure)

    # Increase if pressure is low, decrease if high.
    @reference_level + adjust
  end

  defp get_speed(loop) do
    AutoNuke.API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED")
  end

  defp set_speed(loop, value) do
    AutoNuke.API.put("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", value)
  end

  defp axis_to_speed(output), do: 50 + round(output * 50)
  defp speed_to_axis(speed), do: (speed - 50) / 50
end
