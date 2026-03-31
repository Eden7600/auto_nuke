defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:pump_speed, :smoothed_temp]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Allowed pump speeds.
  # I'm told that <10% is dangerous and >50% is useless.
  # Also, there's the "keep pumps below 50%" objective to think about.
  @pump_min 10
  @pump_max 49
  # Scale pumps from @pump_min speed at @temp_min, to @pump_max speed at @temp_max.
  @temp_min 320
  @temp_max 400
  # Use the average temperature from the last five in-game minutes.
  @temp_smoothing AutoNuke.Ticker.ticks_per_minute() * 5

  # We'll use the raw indices here for convenience, since they aren't shown to the user.
  @loops 0..2

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
    @loops
    |> Enum.map(&get_pump_speed/1)
    |> Enum.reject(&(&1 < @pump_min))
    |> then(fn
      # If all pumps are below minimum, then just use that.
      # (I don't forsee ever having pumps above maximum.)
      [] -> [@pump_min]
      speeds when is_list(speeds) -> speeds
    end)
    |> Statistex.average()
  end

  defp set_pump_speeds(speed) when speed >= @pump_min and speed <= @pump_max do
    @loops |> Enum.each(&set_pump_speed(&1, speed))
  end

  defp get_temperature(), do: API.get_float("CORE_TEMP")

  defp get_pump_speed(n), do: API.get_float("COOLANT_CORE_CIRCULATION_PUMP_#{n}_SPEED")
  defp set_pump_speed(n, v), do: API.put("COOLANT_CORE_CIRCULATION_PUMP_#{n}_ORDERED_SPEED", v)

  @temp_span @temp_max - @temp_min
  @pump_span @pump_max - @pump_min

  defp temp_to_speed(temp) do
    percent_in_range = (temp - @temp_min) / @temp_span

    (@pump_min + @pump_span * percent_in_range)
    |> round()
    |> max(@pump_min)
    |> min(@pump_max)
  end
end
