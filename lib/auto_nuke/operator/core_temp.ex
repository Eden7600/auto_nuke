defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:vessels, :axis]
    defstruct(
      vessels: nil,
      axis: nil,
      override: nil
    )
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

  # Clamp values to within 5°C of current temperature.
  @clamp_temp_delta 5
  # Note: This will decrease as we approach @temp_range bounds.

  def start_link(opts \\ []) do
    {loops, opts} = Keyword.pop(opts, :loops, :detect)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, loops, opts)
  end

  def set_override(temp, pid \\ __MODULE__)
      when temp >= @temp_range.first and temp <= @temp_range.last do
    temp = temp + 0.0
    GenServer.call(pid, {:set_override, temp})
  end

  def clear_override(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_override)
  end

  @impl true
  def init(:detect) do
    AutoNuke.Operator.SteamFlow.get_closed_breakers()
    |> init()
  end

  @impl true
  def init(loops) when is_list(loops) do
    temp = get_core_temp()
    vessels = loops |> Enum.map(&API.Vessels.steam_generator/1)

    axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.0005,
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
  def handle_call({:set_override, temp}, _from, %State{} = state) when is_float(temp) do
    Logger.info(@log_prefix <> "Overriding temperature to #{temp}°C.")

    axis = state.axis |> ControlAxis.clamp(temp)
    {:reply, :ok, %State{state | axis: axis, override: temp}}
  end

  @impl true
  def handle_call(:clear_override, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Clearing override.")
    {:reply, :ok, %State{state | override: nil}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{override: temp} = state) when is_float(temp) do
    PubSub.publish(:core_temp, {:core_temp, temp})
    {:noreply, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    current_pressure = get_current_pressure(state.vessels)

    case ControlAxis.step(state.axis, @target_pressure, current_pressure) do
      {:changed, axis, new, _old} ->
        publish_core_temp(axis, new)

      {:unchanged, axis, old} ->
        publish_core_temp(axis, old)
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis}}
    end)
  end

  defp publish_core_temp(axis, wanted) do
    current = get_core_temp()
    min_temp = min_relative(current) |> clamp_to_range(@temp_range)
    max_temp = max_relative(current) |> clamp_to_range(@temp_range)

    {action, new_temp} =
      cond do
        wanted < min_temp -> {:clamp, min_temp}
        wanted > max_temp -> {:clamp, max_temp}
        true -> {:allow, wanted}
      end

    PubSub.publish(:core_temp, {:core_temp, new_temp})

    case action do
      :allow -> axis
      :clamp -> ControlAxis.clamp(axis, temp_to_axis(new_temp), new_temp)
    end
  end

  @relative_low @temp_range.first + @clamp_temp_delta * 2
  @relative_high @temp_range.last - @clamp_temp_delta * 2

  defp min_relative(temp) when temp < @relative_low do
    # Half of the distance to the lower bound:
    temp - (temp - @temp_range.first) / 2
  end

  defp min_relative(temp), do: temp - @clamp_temp_delta

  defp max_relative(temp) when temp > @relative_high do
    # Half of the distance to the upper bound:
    temp + (@temp_range.last - temp) / 2
  end

  defp max_relative(temp), do: temp + @clamp_temp_delta

  defp clamp_to_range(value, low..high//_) when is_float(value) do
    value
    |> max(low)
    |> min(high)
    |> Kernel.+(0.0)
  end

  defp get_current_pressure([]) do
    # No active loops, reactor idle.  Pretend current pressure is a bit too
    # high, so we slowly slew our target temperature towards the minimum.
    @target_pressure + @deadzone * 1.1
  end

  defp get_current_pressure(vessels) do
    vessels
    |> Enum.map(&API.Vessels.get_pressure/1)
    |> Statistex.average()
  end

  defp get_core_temp do
    API.Vessels.core_vessel()
    |> API.Vessels.get_temperature()
  end

  @temp_span (@temp_range.last - @temp_range.first) / 2
  @temp_midpoint @temp_range.first + @temp_span
  defp axis_to_temp(output), do: (@temp_midpoint + output * @temp_span) |> Float.round(2)
  defp temp_to_axis(temp), do: (temp - @temp_midpoint) / @temp_span
end
