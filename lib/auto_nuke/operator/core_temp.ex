defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:vessels, :axis]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Target 60 bar of pressure, plus or minus half a bar.
  @target_pressure 60
  @deadzone 0.5

  # Temperature range: 300°C to 400°C.
  @temp_range 300..400
  # We could probably go lower, but I don't want to risk turbine stalls.
  def temp_range, do: @temp_range

  def start_link(opts \\ []) do
    {loops, opts} = Keyword.pop(opts, :loops, :detect)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, loops, opts)
  end

  @impl true
  def init(:detect) do
    AutoNuke.Operator.SteamFlow.get_closed_breakers()
    |> init()
  end

  @impl true
  def init(loops) when is_list(loops) do
    temp =
      API.Vessels.core_vessel()
      |> API.Vessels.get_temperature()

    vessels = loops |> Enum.map(&API.Vessels.steam_generator/1)

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

    state = %State{vessels: vessels, axis: axis}

    PubSub.subscribe(self(), :ticker)

    Logger.info([
      @log_prefix,
      "Started with loops #{inspect(loops)}",
      " and temperature #{inspect(temp)}°C."
    ])

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    min_pressure = get_min_pressure(state.vessels)

    case ControlAxis.step(state.axis, @target_pressure, min_pressure) do
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

  defp get_min_pressure([]) do
    # No active loops, reactor idle.  Pretend minimum pressure is a bit too
    # high, so we slowly slew our target temperature towards the minimum.
    @target_pressure + @deadzone * 1.1
  end

  defp get_min_pressure(vessels) do
    vessels
    |> Enum.map(&API.Vessels.get_pressure/1)
    |> Enum.min()
  end

  @temp_span (@temp_range.last - @temp_range.first) / 2
  @temp_midpoint @temp_range.first + @temp_span
  defp axis_to_temp(output), do: (@temp_midpoint + output * @temp_span) |> Float.round(2)
  defp temp_to_axis(temp), do: (temp - @temp_midpoint) / @temp_span
end
