defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:pump_speed, :last_temp, :bypass, :pressure]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Allowed pump speeds. I'm told >50% is useless, and there's the "keep below
  # 50%" objective, so 49 is our max.  10% is our arbitrarily set low, but we
  # may never reach that due to temperature limitations.
  @pump_speeds 5..49
  # High and low steam amounts.  If we're sending at least 50 kg/min through
  # bypass on ALL turbines, try increasing pumps (thus reducing temperature).
  @bypass_high 50
  # If our pressure on ANY turbine is 60 bar or lower,
  # try reducing pumps (thus increasing temperature).
  @pressure_low 60
  # Stop pushing pumps if temperatures drop below 300°C or rise above 400°C.
  @temp_low 300
  @temp_high 400
  # Immediately back off if temperatures drop below 290°C or rise above 410°C.
  @crit_low 290
  @crit_high 410

  # Used by the `startup` task to know what speed to set on cold start.
  def min_speed, do: @pump_speeds.first

  @pumps API.Pumps.all_primary()
  @core API.Vessels.core_vessel()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    speed = get_average_pump_speed() |> round()

    state =
      %State{
        pump_speed: speed,
        last_temp: get_temperature(),
        bypass: nil,
        pressure: nil
      }

    PubSub.subscribe(self(), :ticker)
    PubSub.subscribe(self(), :steam_flow)
    temp = get_temperature() |> Float.round(1)
    Logger.info(@log_prefix <> "Started with temperature #{temp}°C, pumps at #{speed}%.")
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
    state
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    cond do
      state.pressure |> Enum.any?(&(&1 <= @pressure_low)) ->
        state |> adjust_pumps(-1, "Low pressure(s): #{show_pressure(state.pressure)}")

      state.bypass |> Enum.all?(&(&1 >= @bypass_high)) ->
        state |> adjust_pumps(+1, "High bypass: #{show_bypass(state.bypass)}")

      true ->
        state |> adjust_pumps(0, "All systems nominal")
    end
    |> then(fn %State{} = state -> {:noreply, state} end)
  end

  defp adjust_pumps(%State{} = state, change, reason) do
    temp = get_temperature()

    cond do
      temp >= @crit_high ->
        if temp >= state.last_temp do
          state |> backoff_pumps(+3, temp)
        else
          state |> hold_pumps(reason, "critical", temp)
        end

      temp <= @crit_low ->
        if temp <= state.last_temp do
          state |> backoff_pumps(-3, temp)
        else
          state |> hold_pumps(reason, "critical", temp)
        end

      change == 0 ->
        state

      change < 0 && temp >= @temp_high ->
        state |> hold_pumps(reason, "high", temp)

      change > 0 && temp <= @temp_low ->
        state |> hold_pumps(reason, "low", temp)

      true ->
        state
        |> change_pumps(change, fn {_, msg} ->
          Logger.info(@log_prefix <> reason <> ".  " <> msg)
        end)
    end
    |> then(fn %State{} = state -> %State{state | last_temp: temp} end)
  end

  defp backoff_pumps(state, change, temp) do
    reason = "Critical temperature: #{Float.round(temp, 2)}."

    state
    |> change_pumps(change, fn
      {:ok, msg} -> Logger.warning(@log_prefix <> reason <> "  " <> msg)
      {:at_limit, msg} -> Logger.error(@log_prefix <> reason <> "  " <> msg)
    end)
  end

  defp hold_pumps(state, reason, high_low, temp) do
    Logger.notice([
      @log_prefix,
      reason,
      " but #{high_low} temperature: #{Float.round(temp, 2)}°C.",
      "  Leaving pumps at #{state.pump_speed}%."
    ])

    state
  end

  defp change_pumps(state, 0, result_fn) do
    result_fn.({:unchanged, "Pumps remain at #{state.pump_speed}%."})
    state
  end

  defp change_pumps(%State{} = state, change, result_fn) do
    old_speed = state.pump_speed
    new_speed = (old_speed + change) |> clamp(@pump_speeds)
    verb = if change > 0, do: "increase", else: "decrease"

    if old_speed == new_speed do
      result_fn.({:at_limit, "Cannot #{verb} pump speeds beyond #{old_speed}%."})
      state
    else
      set_pump_speeds(new_speed)
      result_fn.({:ok, "Pump speeds changed to #{new_speed}%."})
      %State{state | pump_speed: new_speed}
    end
  end

  defp get_average_pump_speed do
    @pumps
    |> Enum.map(&API.Pumps.get_ordered_speed/1)
    |> Enum.reject(&(&1 not in @pump_speeds))
    |> then(fn
      # If all pumps are out of range, assume minimum.
      [] -> [@pump_speeds.first]
      speeds when is_list(speeds) -> speeds
    end)
    |> Statistex.average()
  end

  defp set_pump_speeds(speed) when speed in @pump_speeds do
    @pumps |> Enum.each(&API.Pumps.set_speed(&1, speed))
  end

  defp get_temperature(), do: API.Vessels.get_temperature(@core)

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
