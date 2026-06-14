defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:axis]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Target 60 bar of pressure, plus or minus 1 bar.
  @target_pressure 60
  @deadzone 1

  # Temperature range: 300°C to 400°C.
  @temp_range 300..400
  # We could probably go lower, but I don't want to risk turbine stalls.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    temp =
      API.Vessels.core_vessel()
      |> API.Vessels.get_temperature()

    axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.001,
        kd: 0.001,
        deadzone: @deadzone,
        to_value_fn: &axis_to_temp/1,
        offset: temp |> temp_to_axis(),
        initial_value: temp
      )

    state = %State{axis: axis}

    PubSub.subscribe(self(), :steam_flow)
    Logger.info(@log_prefix <> "Started with temperature #{inspect(temp)}°C.")
    {:ok, state}
  end

  @impl true
  def handle_info({:steam_flow, []}, %State{} = state) do
    # If no turbines are currently active, we'll consider the reactor idle.
    # Let's gradually drop the temperature down to the minimum
    # by pretending that the turbines are slightly over pressure.
    fake_pressure = @target_pressure + @deadzone * 1.1
    handle_info({:steam_flow, [fake_pressure]}, state)
  end

  @impl true
  def handle_info({:steam_flow, pressures}, %State{axis: axis} = state)
      when is_list(pressures) do
    case ControlAxis.step(axis, @target_pressure, Enum.min(pressures)) do
      {:changed, axis, new, old} ->
        Logger.debug(@log_prefix <> "Changing temperature from #{old}°C to #{new}°C.")
        PubSub.publish(:core_temp, {:core_temp, new})
        axis

      {:unchanged, axis, old} ->
        PubSub.publish(:core_temp, {:core_temp, old})
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis}}
    end)
  end

  @temp_span (@temp_range.last - @temp_range.first) / 2
  @temp_midpoint @temp_range.first + @temp_span
  defp axis_to_temp(output), do: round(@temp_midpoint + output * @temp_span)
  defp temp_to_axis(temp), do: (temp - @temp_midpoint) / @temp_span
end
