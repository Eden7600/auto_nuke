defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  # Run on the second tick each second:
  @ticks_per_second AutoNuke.Ticker.ticks_per_second()
  defguard is_my_tick(t) when rem(t, @ticks_per_second) == 1

  defmodule State do
    @enforce_keys [:pump_speed, :smoothed_temp]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Allowed pump speeds.
  # I'm told that <10% is dangerous and >50% is useless.
  # Also, there's the "keep pumps below 50%" objective to think about.
  @pump_speeds 10..49
  # Scale pumps from min speed at @temp_min, to max speed at @temp_max.
  @temp_min 320
  @temp_max 400
  # Use the average temperature from the last five in-game minutes.
  @temp_smoothing AutoNuke.Ticker.seconds_per_minute() * 5

  @pumps API.Pumps.all_primary()
  @core API.Vessels.core_vessel()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    speed = get_average_pump_speed()
    temp = get_temperature()
    smoother = Smoother.new(@temp_smoothing) |> Smoother.add(temp)

    state =
      %State{
        pump_speed: speed,
        smoothed_temp: smoother
      }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with temperature #{temp}°C, pumps at #{speed}.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    smoother = state.smoothed_temp |> Smoother.add(get_temperature())
    temp = Smoother.average(smoother)

    old = state.pump_speed
    new = temp_to_speed(temp)

    if new != old do
      Logger.info(@log_prefix <> "Changing pump speeds from #{old} to #{new}.")
      set_pump_speeds(new)
    end

    {:noreply, %State{state | pump_speed: new, smoothed_temp: smoother}}
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

  @temp_span @temp_max - @temp_min
  @pump_span @pump_speeds.last - @pump_speeds.first

  defp temp_to_speed(temp) do
    percent_in_range = (temp - @temp_min) / @temp_span

    (@pump_speeds.first + @pump_span * percent_in_range)
    |> round()
    |> clamp(@pump_speeds)
  end

  defp clamp(value, min..max//1) do
    value
    |> max(min)
    |> min(max)
  end
end
