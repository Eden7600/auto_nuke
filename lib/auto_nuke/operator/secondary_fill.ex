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

  # If fill level is within 1% of target,
  # just try to balance inlet and outlet.
  @fill_level_deadzone 0.01
  # If fill level is >= 80%, stop pumps immediately.
  @fill_max 0.8

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
        kp: 0.1,
        ki: 0.01,
        kd: 0.005,
        deadzone: 0.02,
        to_value_fn: &axis_to_speed/1,
        offset: speed |> speed_to_axis(),
        initial_value: speed
      )

    state = %State{
      loop: loop,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)

    fill_level = (get_current_fill_percent(loop) * 100) |> Float.round(2)
    Logger.info(log_prefix(loop) <> "Started with fill level of #{fill_level}%.")

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{loop: loop} = state) do
    current = get_current_ratio(loop)
    target = get_target_ratio(loop)

    case ControlAxis.step(state.axis, target, current) do
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

  defp get_current_fill_percent(loop) do
    AutoNuke.API.get_float("COOLANT_SEC_#{loop - 1}_LIQUID_VOLUME") / @tank_size
  end

  defp get_target_fill_percent(loop) do
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

  defp get_current_ratio(loop) do
    inlet = AutoNuke.API.get_float("STEAM_GEN_#{loop - 1}_INLET")
    outlet = AutoNuke.API.get_float("STEAM_GEN_#{loop - 1}_OUTLET")

    cond do
      outlet > 0 -> inlet / outlet
      # If we have zero outlet, any inlet is too high.
      # We return a conservatively high value that should
      # gently convince the PID controller to reduce input to 0.
      # But we keep this low enough that a very low fill level
      # can still override it and start filling an empty tank.
      inlet > 0 -> 1.5
      # Consider the ratio satisfied.
      true -> 1.0
    end
  end

  defp get_target_ratio(loop) do
    current_fill = get_current_fill_percent(loop)
    target_fill = get_target_fill_percent(loop)
    fill_ratio = current_fill / target_fill
    delta = abs(1.0 - fill_ratio)

    cond do
      # Too full, stop pumps!
      current_fill >= @fill_max -> -1
      # Avoids divide-by-zero and sets pumps to max.
      fill_ratio < 0.05 -> 10.0
      # Within deadzone, just balance inlet/outlet.
      delta < @fill_level_deadzone -> 1.0
      # Adjust inlet/outlet to reach target.
      true -> 1 / fill_ratio
    end
  end

  defp get_speed(loop) do
    AutoNuke.API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED")
  end

  defp set_speed(loop, value) do
    AutoNuke.API.put("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", value)
  end

  def axis_to_speed(output), do: round(50 + output * 50)
  def speed_to_axis(speed), do: (speed - 50) / 50

  defp log_prefix(loop), do: "[#{inspect(__MODULE__)}.L#{loop}] "
end
