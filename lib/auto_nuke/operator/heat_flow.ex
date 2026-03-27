defmodule AutoNuke.Operator.HeatFlow do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:loop, :axis]
    defstruct(
      loop: nil,
      axis: nil
    )
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  # Target 60 bar of pressure, plus or minus 1 bar.
  @target_pressure 60
  @deadzone 1

  # Don't let pumps drop below 5%.
  # If that's still too much heat, we fall back to SteamFlow pressure relief logic.
  @min_speed 5

  def child_spec(opts) do
    loop = Keyword.fetch!(opts, :loop)

    %{
      id: __MODULE__ |> Module.concat("L#{loop}"),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    {loop, opts} = Keyword.pop!(opts, :loop)
    GenServer.start_link(__MODULE__, loop, opts)
  end

  @impl true
  def init(loop) do
    get_speed(loop)
    |> do_init(loop)
  end

  defp do_init(speed, loop) when speed < 0.5 do
    Logger.info(log_prefix(loop) <> "Pump is not active.")
    {:ok, nil}
  end

  defp do_init(speed, loop) do
    axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.001,
        kd: 0.001,
        deadzone: @deadzone,
        to_value_fn: &axis_to_speed/1,
        offset: speed |> speed_to_axis(),
        initial_value: speed
      )

    state = %State{
      loop: loop,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(log_prefix(loop) <> "Started with speed #{inspect(speed)}.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{loop: loop, axis: axis} = state) do
    case ControlAxis.step(axis, @target_pressure, get_pressure(loop)) do
      {:changed, axis, new, old} ->
        Logger.info(log_prefix(loop) <> "Changing speed from #{old} to #{new}.")
        set_speed(loop, new)
        axis

      {:unchanged, axis, _old} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis}}
    end)
  end

  defp get_speed(loop),
    do: API.get_float("COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_SPEED")

  defp set_speed(loop, value),
    do: API.put("COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", value)

  defp get_pressure(loop), do: API.get_float("COOLANT_SEC_#{loop - 1}_PRESSURE")

  @speed_span (100 - @min_speed) / 2
  @speed_midpoint @min_speed + @speed_span
  defp axis_to_speed(output), do: round(@speed_midpoint + output * @speed_span)
  defp speed_to_axis(speed), do: (speed - @speed_midpoint) / @speed_span

  @module_name inspect(__MODULE__)
  defp log_prefix(loop), do: "[#{@module_name}.L#{loop}] "
end
