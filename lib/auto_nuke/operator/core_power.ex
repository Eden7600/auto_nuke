defmodule AutoNuke.Operator.CorePower do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:target, :bypass, :pressure]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Allowed temperature range.
  @temp_range 320..400
  def temp_range, do: @temp_range
  # High and low steam amounts.  If we're sending at least 25 kg/min through
  # bypass on ALL turbines, AND pressure is above 64 bar, try reducing temperature.
  # (The pressure check is to avoid "only bypassing because minimum steam" situations.)
  @bypass_high 25
  @pressure_high 64
  # If our pressure on ANY turbine is 60 bar or lower, try increasing temperature.
  @pressure_low 60

  # Used by the `startup` task to know what temperature to aim for on cold start.
  def min_temperature, do: @temp_range.first

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    temp =
      API.Vessels.core_vessel()
      |> API.Vessels.get_temperature()
      |> round()
      |> clamp(@temp_range)

    state =
      %State{
        target: temp,
        bypass: nil,
        pressure: nil
      }

    PubSub.subscribe(self(), :ticker)
    PubSub.subscribe(self(), :steam_flow)
    Logger.info(@log_prefix <> "Started with target temperature #{temp}°C.")
    {:ok, state}
  end

  @impl true
  def handle_info({:steam_flow, bypass, pressure}, %State{} = state) do
    {:noreply, %State{state | bypass: bypass, pressure: pressure}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{bypass: nil} = state) do
    Logger.warning(@log_prefix <> "No bypass data received yet.")
    {:noreply, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    cond do
      state.pressure |> Enum.any?(&(&1 <= @pressure_low)) ->
        state |> adjust_temperature(+5, "Low pressure(s): #{show_pressure(state.pressure)}")

      state.bypass |> Enum.all?(&(&1 >= @bypass_high)) &&
          state.pressure |> Enum.all?(&(&1 >= @pressure_high)) ->
        state |> adjust_temperature(-1, "High bypass: #{show_bypass(state.bypass)}")

      true ->
        state |> adjust_temperature(0, "All systems nominal")
    end
    |> then(fn %State{} = state -> {:noreply, state} end)
  end

  defp adjust_temperature(state, 0, _), do: state

  defp adjust_temperature(%State{} = state, change, reason) do
    old_temp = state.target
    new_temp = (current_temperature() + change) |> clamp(@temp_range)

    if new_temp != old_temp do
      Logger.info(@log_prefix <> reason)
      AutoNuke.Operator.CoreTemp.set_target(new_temp)
      %State{state | target: new_temp}
    else
      state
    end
  end

  @core API.Vessels.core_vessel()
  defp current_temperature, do: @core |> API.Vessels.get_temperature() |> round()

  defp clamp(value, min..max//1) do
    value
    |> max(min)
    |> min(max)
  end

  defp show_bypass(bypass) do
    bypass
    |> Enum.filter(&(&1 >= @bypass_high))
    |> Enum.map(&ceil/1)
    |> Enum.join(", ")
    |> then(&"#{&1} kg/min")
  end

  defp show_pressure(pressure) do
    pressure
    |> Enum.filter(&(&1 <= @pressure_low))
    |> Enum.map(&floor/1)
    |> Enum.join(", ")
    |> then(&"#{&1} bar")
  end
end
