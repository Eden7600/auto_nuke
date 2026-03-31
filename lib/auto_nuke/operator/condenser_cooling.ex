defmodule AutoNuke.Operator.CondenserCooling do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:axis, :last_temp]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Range of allowed speeds.
  @speeds 10..100
  @speed_span (@speeds.last - @speeds.first) / 2
  # Target 5°C above ambient.
  @above_ambient 5.0

  # Low-pass filter quotient.  Must be between 0.0 and 1.0.
  # Filters out high-frequency noise in the temperature,
  # e.g. the erroneous readings we sometimes get for a single reading.
  # Set higher for more smoothing, lower for less.
  @lpf_factor 0.75
  # The pump can only scale up so fast.
  # If we start asking for pump speeds that are 2+ above our current speed,
  # clamp down to prevent integral windup.
  @clamping 2

  defp axis_to_speed(output), do: round((output + 1.0) * @speed_span + @speeds.first)
  defp speed_to_axis(speed), do: (speed - @speeds.first) / @speed_span - 1.0

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    temp = get_temperature()
    speed = get_pump_speed()

    axis =
      ControlAxis.new(
        kp: -0.01,
        ki: -0.005,
        deadzone: 0.5,
        to_value_fn: &axis_to_speed/1,
        offset: speed |> speed_to_axis(),
        initial_value: speed
      )

    state = %State{axis: axis, last_temp: temp}

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with temperature #{temp}°C, pump at #{speed}.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    temp = get_temperature() |> low_pass_filter(state.last_temp)
    target = get_ambient() + @above_ambient

    case ControlAxis.step(state.axis, target, temp) do
      {:changed, new_axis, new, old} ->
        Logger.info(@log_prefix <> "Changing pump speed from #{old} to #{new}.")
        set_pump_speed(new)
        maybe_clamp(new_axis, new)

      {:unchanged, new_axis, _old_value} ->
        new_axis
    end
    |> then(fn %ControlAxis{} = new_axis ->
      {:noreply, %State{state | axis: new_axis, last_temp: temp}}
    end)
  end

  defp low_pass_filter(new, old), do: (1 - @lpf_factor) * new + @lpf_factor * old

  defp maybe_clamp(axis, ordered) do
    actual = get_pump_speed()

    if ordered - actual > @clamping do
      # We're asking for too much pump speed at once, clamp down.
      Logger.debug(@log_prefix <> "Clamping down to #{actual + @clamping}")
      clamp_to = (actual + @clamping) |> speed_to_axis()
      axis |> ControlAxis.clamp_min(clamp_to)
    else
      axis
    end
  end

  defp get_temperature, do: API.get_float("CONDENSER_TEMPERATURE")
  defp get_ambient, do: API.get_float("AMBIENT_TEMPERATURE")

  defp get_pump_speed, do: API.get_float("CONDENSER_CIRCULATION_PUMP_SPEED")
  defp set_pump_speed(v), do: API.put("CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED", v)
end
