defmodule AutoNuke.Operator.CondenserCooling do
  use GenServer
  require Logger

  alias AutoNuke.Smoother

  defmodule State do
    # Smooth temperature as an average of the last minute.
    @temperature_smoothing AutoNuke.Ticker.ticks_per_minute()

    @enforce_keys [:axis]
    defstruct(
      axis: nil,
      smoothed: Smoother.new(@temperature_smoothing)
    )
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Range of allowed speeds.
  @speeds 10..100
  @speed_span (@speeds.last - @speeds.first) / 2
  # Target 5°C above ambient.
  @above_ambient 5.0

  defp axis_to_speed(output), do: round((output + 1.0) * @speed_span + @speeds.first)
  defp speed_to_axis(speed), do: (speed - @speeds.first) / @speed_span - 1.0

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    temp = get_temperature()
    speed = get_pump_speed()

    axis =
      ControlAxis.new(
        kp: -0.05,
        ki: -0.01,
        deadzone: 0.5,
        to_value_fn: &axis_to_speed/1,
        offset: speed |> speed_to_axis(),
        initial_value: speed
      )

    state = %State{axis: axis}

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with temperature #{temp}°C, pump at #{speed}.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    raw_temp = get_temperature()
    smoothed = state.smoothed |> Smoother.add(raw_temp)
    temp = Smoother.average(smoothed)
    target = get_ambient() + @above_ambient

    case ControlAxis.step(state.axis, target, temp) do
      {:changed, new_axis, new, old} ->
        Logger.info(@log_prefix <> "Changing pump speed from #{old} to #{new}.")
        set_pump_speed(new)
        new_axis

      {:unchanged, new_axis, _old_value} ->
        new_axis
    end
    |> then(fn %ControlAxis{} = new_axis ->
      {:noreply, %State{state | axis: new_axis, smoothed: smoothed}}
    end)
  end

  defp get_temperature, do: API.get_float("CONDENSER_TEMPERATURE")
  defp get_ambient, do: API.get_float("AMBIENT_TEMPERATURE")

  defp get_pump_speed, do: API.get_float("CONDENSER_CIRCULATION_PUMP_SPEED")
  defp set_pump_speed(v), do: API.put("CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED", v)
end
