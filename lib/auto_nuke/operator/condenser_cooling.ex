defmodule AutoNuke.Operator.CondenserCooling do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:speed, :last_temp, :last_direction, :probe_timer]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Range of allowed speeds.
  @speeds 10..100
  # Violation threshold is 10°C above ambient.
  @above_ambient 10.0
  # Wait 30 in-game minutes after a violation to begin probing lower speeds:
  @wait_after_violation 30 * AutoNuke.Ticker.ticks_per_minute()
  # While probing, wait 10 in-game minutes per 1% speed drop:
  @wait_while_probing 10 * AutoNuke.Ticker.ticks_per_minute()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    temp = get_temperature()
    speed = get_pump_speed()

    state = %State{
      speed: speed,
      last_temp: temp,
      last_direction: :stable,
      probe_timer: @wait_while_probing
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with temperature #{temp}°C, pump at #{speed}.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    new_temp = get_temperature()
    old_temp = state.last_temp
    threshold = get_ambient() + @above_ambient

    status =
      cond do
        new_temp >= threshold -> :above
        new_temp < threshold -> :below
      end

    direction =
      cond do
        abs(new_temp - old_temp) < 0.01 -> :stable
        new_temp > old_temp -> :increasing
        new_temp < old_temp -> :decreasing
      end

    # We track both the current direction and the previous direction,
    # to avoid momentary reading glitches from throwing us off.

    case {status, direction, state.last_direction} do
      # === Above threshold: ===
      # - Steadily increasing: Backoff by 3%.
      {:above, :increasing, :increasing} -> backoff(state, 3, new_temp)
      # - Decreasing: Good, but hold off on probing until we're safe.
      {:above, :decreasing, _} -> probe_wait(state, @wait_after_violation)
      {:above, _, :decreasing} -> probe_wait(state, @wait_after_violation)
      # - Any other situation: Let's back off to get it below the threshold.
      {:above, _, _} -> backoff(state, 1, new_temp)
      # 
      # === Below threshold: ===
      # - Steadily increasing: Hold off on probing.
      {:below, :increasing, :increasing} -> probe_wait(state, @wait_while_probing)
      # - Recent increase: Skip the timer for this tick.
      {:below, :increasing, _} -> state
      {:below, _, :increasing} -> state
      # - No recent increases: Begin probing downwards.
      {:below, _, _} -> maybe_probe(state, new_temp)
    end
    |> then(fn %State{} = new_state ->
      {:noreply, %State{new_state | last_temp: new_temp, last_direction: direction}}
    end)
  end

  defp backoff(%State{} = state, amount, temp) do
    old = state.speed
    new = (get_pump_speed() + amount) |> min(@speeds.last)

    Logger.info(
      @log_prefix <> "Temperature violation at #{temp}°C, backing off from #{old} to #{new}."
    )

    set_pump_speed(new)
    %State{state | speed: new, probe_timer: @wait_after_violation}
  end

  defp probe_wait(%State{} = state, wait) do
    %State{state | probe_timer: max(state.probe_timer, wait)}
  end

  defp maybe_probe(%State{probe_timer: timer} = state, _) when timer > 0 do
    %State{state | probe_timer: timer - 1}
  end

  defp maybe_probe(%State{speed: speed} = state, _) when speed <= @speeds.first do
    state
  end

  defp maybe_probe(%State{} = state, temp) do
    new = state.speed - 1
    Logger.info(@log_prefix <> "Temperature steady at #{temp}°C, probing down to #{new}.")
    set_pump_speed(new)
    %State{state | speed: new, probe_timer: @wait_while_probing}
  end

  defp get_temperature, do: API.get_float("CONDENSER_TEMPERATURE")
  defp get_ambient, do: API.get_float("AMBIENT_TEMPERATURE")

  defp get_pump_speed, do: API.get_float("CONDENSER_CIRCULATION_PUMP_SPEED") |> round()
  defp set_pump_speed(v), do: API.put("CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED", v)
end
