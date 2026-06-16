defmodule AutoNuke.Operator.PrimaryPumps do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:pump_speed, :last_temp]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @core API.Vessels.core_vessel()

  # Allowed pump speeds.
  # I'm told that above 50% is useless, plus there's the "keep pumps below 50%" objective.
  @pump_speeds 5..49
  def speed_range, do: @pump_speeds
  # Scale pumps from min speed at @temp_min, to max speed at @temp_max.
  @temp_min 300
  @temp_max 400
  # Apply a deadband of 0.7 to limit speed oscillation.
  # So to get from 22 to 23 speed, you need to hit 22.7, not 22.5.
  @speed_deadband 0.7

  @pumps API.Pumps.all_primary()
  @core API.Vessels.core_vessel()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def get_speed(pid \\ __MODULE__) do
    GenServer.call(pid, :get_speed)
  end

  @impl true
  def init(_) do
    speed = get_average_pump_speed()
    temp = get_temperature()

    state =
      %State{
        pump_speed: speed,
        last_temp: temp
      }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with temperature #{temp}°C, pumps at #{speed}.")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_speed, _from, %State{pump_speed: speed} = state) do
    {:reply, speed, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    temp = get_verified_core_temp([state.last_temp])

    old = state.pump_speed
    new = temp_to_speed(temp, old)

    if new != old do
      Logger.info(@log_prefix <> "Changing pump speeds from #{old} to #{new}.")
      set_pump_speeds(new)
    end

    {:noreply, %State{state | pump_speed: new, last_temp: temp}}
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

  # Avoid transients:
  defp get_verified_core_temp(seen) do
    temp = API.Vessels.get_temperature(@core)

    if temp in seen do
      temp
    else
      Process.sleep(20)
      get_verified_core_temp([temp | seen])
    end
  end

  @temp_span @temp_max - @temp_min
  @pump_span @pump_speeds.last - @pump_speeds.first

  defp temp_to_speed(temp, old_speed) do
    percent_in_range = (temp - @temp_min) / @temp_span
    new_speed = @pump_speeds.first + @pump_span * percent_in_range

    # Apply a deadband around the prior value.
    upper = old_speed + @speed_deadband
    lower = old_speed - @speed_deadband

    if new_speed >= upper || new_speed <= lower do
      new_speed
      |> round()
      |> clamp(@pump_speeds)
    else
      old_speed
    end
  end

  defp clamp(value, min..max//1) do
    value
    |> max(min)
    |> min(max)
  end
end
