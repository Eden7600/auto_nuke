defmodule AutoNuke.Operator.PrimaryPumps do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:pump_speed, :target_temp, :loops]
    # Loops that were just added: their pump gets the current speed written
    # again on the next tick, regardless of whether the speed changed.
    defstruct(@enforce_keys ++ [sync: []])
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
  # Apply a deadband to limit oscillation.
  # Calculated speed needs to differ from current speed by
  # at least this much for any change to occur.
  @speed_deadband 1.4

  @loops 1..3

  def start_link(opts \\ []) do
    {loops, opts} = Keyword.pop(opts, :loops, :detect)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, loops, opts)
  end

  def get_speed(pid \\ __MODULE__) do
    GenServer.call(pid, :get_speed)
  end

  def add_loop(loop, pid \\ __MODULE__) when loop in @loops do
    GenServer.call(pid, {:add_loop, loop})
  end

  def remove_loop(loop, pid \\ __MODULE__) when loop in @loops do
    GenServer.call(pid, {:remove_loop, loop})
  end

  def get_loops(pid \\ __MODULE__) do
    GenServer.call(pid, :get_loops)
  end

  @impl true
  def init(:detect) do
    AutoNuke.Operator.SteamFlow.get_closed_breakers()
    |> init()
  end

  @impl true
  def init(loops) when is_list(loops) do
    loops = Enum.sort(loops)
    speed = get_average_pump_speed(loops)
    temp = get_temperature()

    state =
      %State{
        pump_speed: speed,
        target_temp: temp,
        loops: loops
      }

    PubSub.subscribe(self(), :ticker)
    PubSub.subscribe(self(), :core_temp)

    Logger.info(
      @log_prefix <>
        "Started with loops #{inspect(loops)}, temperature #{temp}°C, pumps at #{speed}."
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_speed, _from, %State{pump_speed: speed} = state) do
    {:reply, speed, state}
  end

  @impl true
  def handle_call({:add_loop, loop}, _from, %State{loops: loops} = state) do
    if loop in loops do
      {:reply, {:error, :already_active}, state}
    else
      # Bring the new loop's pump in line with the others right away.
      set_pump_speeds([loop], round(state.pump_speed))
      Logger.info(@log_prefix <> "Added loop #{loop}, setting pump to #{round(state.pump_speed)}.")

      {:reply, :ok,
       %State{state | loops: Enum.sort([loop | loops]), sync: [loop | state.sync]}}
    end
  end

  @impl true
  def handle_call({:remove_loop, loop}, _from, %State{loops: loops} = state) do
    if loop in loops do
      Logger.info(@log_prefix <> "Removed loop #{loop}.")

      {:reply, :ok,
       %State{state | loops: List.delete(loops, loop), sync: List.delete(state.sync, loop)}}
    else
      {:reply, {:error, :not_active}, state}
    end
  end

  @impl true
  def handle_call(:get_loops, _from, %State{loops: loops} = state) do
    {:reply, loops, state}
  end

  @impl true
  def handle_info({:core_temp, t}, %State{} = state) do
    {:noreply, %State{state | target_temp: t}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{loops: []} = state), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    temp = state.target_temp
    old = state.pump_speed
    new = temp_to_speed(temp, old)

    if new != old do
      Logger.info(@log_prefix <> "Changing pump speeds from #{old} to #{new}.")
      set_pump_speeds(state.loops, new)
    else
      # Newly added loops get one more write, in case the first was lost.
      if state.sync != [], do: set_pump_speeds(state.sync, round(new))
    end

    {:noreply, %State{state | pump_speed: new, sync: []}}
  end

  defp get_average_pump_speed(loops) do
    loops
    |> Enum.map(&API.Pumps.primary/1)
    |> Enum.map(&API.Pumps.get_ordered_speed/1)
    |> Enum.reject(&(&1 not in @pump_speeds))
    |> then(fn
      # If all pumps are out of range, assume minimum.
      [] -> [@pump_speeds.first]
      speeds when is_list(speeds) -> speeds
    end)
    |> Statistex.average()
  end

  defp set_pump_speeds(loops, speed) when speed in @pump_speeds do
    loops
    |> Enum.map(&API.Pumps.primary/1)
    |> Enum.each(&API.Pumps.set_speed(&1, speed))
  end

  defp get_temperature(), do: API.Vessels.get_temperature(@core)

  @temp_span @temp_max - @temp_min
  @pump_span @pump_speeds.last - @pump_speeds.first

  defp temp_to_speed(temp, _) when temp <= @temp_min, do: @pump_speeds.first
  defp temp_to_speed(temp, _) when temp >= @temp_max, do: @pump_speeds.last

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
