defmodule AutoNuke.Operator.SecondaryFill do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:loop, :axis]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis

  @tank_size 60000.0

  # Use 50% fill level at 60 bars of pressure.
  @reference_pressure 60
  @reference_level 0.5
  # For every 10 bars deviation, adjust fill level by 5%.
  @adjust_pressure 10
  @adjust_level 0.05

  # Set speed to ideal speed, plus or minus this much based on fill:
  @max_speed_deviation 10

  def child_spec(opts) do
    loop = Keyword.fetch!(opts, :loop)

    %{
      id: __MODULE__ |> Module.concat("L#{loop}"),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    {loop, opts} = Keyword.pop!(opts, :loop)
    GenServer.start_link(__MODULE__, loop, opts)
  end

  @impl true
  def init(loop) when loop in 1..3 do
    if is_installed?(loop) do
      do_init(loop)
    else
      Logger.info(log_prefix(loop) <> "Steam generator is not installed.")
      {:ok, nil}
    end
  end

  defp do_init(loop) do
    speed = get_speed(loop)

    axis =
      ControlAxis.new(
        kp: 1,
        ki: 0.1,
        deadzone: 0.01,
        to_value_fn: &axis_to_speed(&1, loop),
        offset: speed |> speed_to_axis(loop),
        initial_value: speed
      )

    state = %State{
      loop: loop,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)

    fill_level = get_fill_percent(loop) |> Float.round(2)
    Logger.info(log_prefix(loop) <> "Started with fill level of #{fill_level * 100}%.")

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{loop: loop} = state) do
    case ControlAxis.step(state.axis, get_target_percent(loop), get_fill_percent(loop)) do
      {:changed, axis, new, old} ->
        Logger.info(log_prefix(loop) <> "Changing speed from #{old} to #{new}.")
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

  defp is_installed?(loop) do
    AutoNuke.API.get_integer("STEAM_GEN_#{loop - 1}_STATUS") == 2
  end

  defp get_outlet(loop) do
    AutoNuke.API.get_float("STEAM_GEN_#{loop - 1}_OUTLET")
  end

  defp get_speed(loop) do
    AutoNuke.API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED")
  end

  defp set_speed(loop, value) do
    AutoNuke.API.put("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", value)
  end

  defp axis_to_speed(output, loop) do
    round(ideal_speed(loop) + output * @max_speed_deviation)
  end

  defp speed_to_axis(speed, loop) do
    ((speed - ideal_speed(loop)) / @max_speed_deviation)
    |> max(-1.0)
    |> min(1.0)
  end

  defp ideal_speed(loop), do: get_outlet(loop) / 2.0

  defp log_prefix(loop), do: "[#{inspect(__MODULE__)}.L#{loop}] "
end
