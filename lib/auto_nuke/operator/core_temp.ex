defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.LoopIntent
  alias AutoNuke.Operator.CoreTemp.Drift
  alias AutoNuke.Time, as: ANTime
  alias AutoNuke.Tolerance

  defmodule State do
    @enforce_keys [:monitored, :axis]
    defstruct(
      monitored: nil,
      axis: nil,
      override: nil,
      drift: nil
    )
  end

  defmodule MonitoredVessel do
    @enforce_keys [:loop, :vessel, :history]
    defstruct(@enforce_keys)

    alias __MODULE__, as: MV
    alias AutoNuke.Smoother

    @history_size 10
    @lookahead 5

    def new(loop) do
      vessel = API.Vessels.steam_generator(loop)
      pressure = API.Vessels.get_pressure(vessel)

      %MV{
        loop: loop,
        vessel: vessel,
        history: Smoother.new(@history_size) |> Smoother.add(pressure)
      }
    end

    def tick(%MV{vessel: vessel, history: history} = mv) do
      pressure = API.Vessels.get_pressure(vessel)
      %MV{mv | history: history |> Smoother.add(pressure)}
    end

    def guess_future_pressure(%MV{history: h}), do: h |> Smoother.extrapolate(@lookahead)
  end

  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @loops 1..3

  # Target 60 bar of pressure, plus or minus half a bar (the deadzone is
  # Tolerance-scaled — this is where wide temperature-target swings are
  # born, so steadying the plant starts here).
  @target_pressure 60
  @deadzone 0.5

  # Temperature range: 300°C to 400°C.
  @temp_range 300..400
  # We could probably go lower, but I don't want to risk turbine stalls.
  def temp_range, do: @temp_range

  # Clamp values to within +10°C or -5°C of current temperature.
  @clamp_upwards 10
  @clamp_downwards 5
  # If we get within 10°C of the edge of @temp_range, clamp to
  # half the difference between current temperature and that boundary.
  @clamp_near_boundary 10

  def start_link(opts \\ []) do
    {loops, opts} = Keyword.pop(opts, :loops, :detect)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, loops, opts)
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

  def set_override(temp, expiry \\ :next_hour, pid \\ __MODULE__) do
    GenServer.call(pid, {:override, temp + 0.0, ANTime.parse_expiry(expiry)})
  end

  def get_override(pid \\ __MODULE__) do
    GenServer.call(pid, :get_override)
  end

  def clear_override(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_override)
  end

  def drift(opts, pid \\ __MODULE__) do
    opts
    |> Keyword.put_new(:start_time, :now)
    |> Drift.new()
    |> then(&GenServer.call(pid, {:drift, &1}))
  end

  def stop_drift(pid \\ __MODULE__) do
    GenServer.call(pid, :stop_drift)
  end

  @impl true
  def init(:detect) do
    AutoNuke.Operator.SteamFlow.get_closed_breakers()
    |> init()
  end

  @impl true
  def init(loops) when is_list(loops) do
    temp = get_core_temp()
    monitored = loops |> Enum.map(&MonitoredVessel.new/1)

    axis =
      ControlAxis.new(
        kp: 0.02,
        ki: 0.001,
        deadzone: @deadzone,
        to_value_fn: &axis_to_temp/1,
        offset: temp |> temp_to_axis(),
        initial_value: temp
      )

    state = %State{monitored: monitored, axis: axis}

    PubSub.subscribe(self(), :ticker)

    Logger.info([
      @log_prefix,
      "Started with loops #{inspect(loops)}",
      " and temperature #{inspect(temp)}°C."
    ])

    {:ok, state}
  end

  @impl true
  def handle_call({:add_loop, loop}, _from, %State{monitored: old_monitored} = state) do
    LoopIntent.set_active(loop)

    case old_monitored |> Enum.any?(&(&1.loop == loop)) do
      true ->
        {:reply, {:error, :already_active}, state}

      false ->
        new_monitored =
          [MonitoredVessel.new(loop) | old_monitored]
          |> Enum.sort_by(& &1.loop)

        {:reply, :ok, %State{state | monitored: new_monitored}}
    end
  end

  @impl true
  def handle_call({:remove_loop, loop}, _from, %State{monitored: old_monitored} = state) do
    LoopIntent.set_stopped(loop)
    {found, rest} = old_monitored |> Enum.split_with(&(&1.loop == loop))

    case found do
      [] ->
        {:reply, {:error, :not_active}, state}

      [%MonitoredVessel{loop: ^loop}] ->
        {:reply, :ok, %State{state | monitored: rest}}
    end
  end

  @impl true
  def handle_call(:get_loops, _from, %State{monitored: monitored} = state) do
    monitored
    |> Enum.map(& &1.loop)
    |> then(fn loops ->
      {:reply, loops, state}
    end)
  end

  @impl true
  def handle_call({:override, temp, expiry}, _from, %State{} = state) when is_float(temp) do
    expires_desc =
      case expiry do
        :never -> "does not expire"
        ts -> "expires at #{ANTime.timestamp_to_string(ts)}"
      end

    Logger.info(@log_prefix <> "Override set to #{temp}°C, #{expires_desc}.")
    {:reply, :ok, %State{state | override: {temp, expiry}}}
  end

  @impl true
  def handle_call(:get_override, _from, %State{} = state) do
    {:reply, state.override, state}
  end

  @impl true
  def handle_call(:clear_override, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Clearing override.")
    {:reply, :ok, %State{state | override: nil}}
  end

  @impl true
  def handle_call({:drift, %Drift{} = drift}, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Now planning to drift #{Drift.describe(drift)}.")
    {:reply, :ok, %State{state | drift: {drift, false}}}
  end

  @impl true
  def handle_call(:stop_drift, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Cancelling drift.")
    {:reply, :ok, %State{state | drift: nil}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state =
      state
      |> reconcile_loops()
      |> apply_drift()
      |> maybe_expire_override()

    monitored = state.monitored |> Enum.map(&MonitoredVessel.tick/1)

    %State{state | monitored: monitored}
    |> do_tick()
  end

  # Keep our loop list consistent with the plant-wide intent: a task or
  # operator taking a loop out of service must not leave us holding core
  # temperature against its vented steam generator.
  defp reconcile_loops(%State{monitored: monitored} = state) do
    intents = LoopIntent.intents()

    {dropped, kept} = monitored |> Enum.split_with(&(intents[&1.loop] == :stopped))

    dropped
    |> Enum.each(
      &Logger.warning(@log_prefix <> "Loop #{&1.loop} is out of service — dropping it.")
    )

    added =
      intents
      |> Enum.filter(fn {loop, intent} ->
        intent == :active and not Enum.any?(monitored, &(&1.loop == loop))
      end)
      |> Enum.map(fn {loop, _} ->
        Logger.warning(@log_prefix <> "Loop #{loop} is in service but unwatched — adding it.")
        MonitoredVessel.new(loop)
      end)

    %State{state | monitored: (kept ++ added) |> Enum.sort_by(& &1.loop)}
  end

  defp do_tick(%State{override: nil} = state) do
    future_pressure = get_future_pressure(state.monitored)
    axis = %ControlAxis{state.axis | deadzone: Tolerance.deadzone(@deadzone)}

    case ControlAxis.step(axis, @target_pressure, future_pressure) do
      {:changed, axis, new, old} ->
        {new, axis} = maybe_clamp_movement(axis, old, new)
        publish_core_temp(new)
        axis

      {:unchanged, axis, old} ->
        publish_core_temp(old)
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis}}
    end)
  end

  defp do_tick(%State{override: {temp, _expires}} = state) do
    publish_core_temp(temp)
    axis = ControlAxis.clamp(state.axis, temp_to_axis(temp), temp)
    {:noreply, %State{state | axis: axis}}
  end

  defp apply_drift(%State{drift: nil} = state), do: state

  defp apply_drift(%State{drift: {%Drift{} = drift, started}} = state) do
    case Drift.current_value(drift) do
      :not_started ->
        state

      {:drifting, :current} ->
        temp = state.axis.last_value
        drift = %Drift{drift | start_temp: temp}
        Logger.info(@log_prefix <> "Starting drift #{Drift.describe(drift)} ...")
        %State{state | override: {temp, :never}, drift: {drift, true}}

      {:drifting, temp} ->
        case started do
          false ->
            Logger.info(@log_prefix <> "Starting drift #{Drift.describe(drift)} ...")
            %State{state | override: {temp, :never}, drift: {drift, true}}

          true ->
            %State{state | override: {temp, :never}}
        end

      {:complete, temp} ->
        %State{state | override: {temp, :never}, drift: nil}
    end
  end

  defp maybe_expire_override(%State{override: nil} = state), do: state
  defp maybe_expire_override(%State{override: {_, :never}} = state), do: state

  defp maybe_expire_override(%State{override: {_, ts}} = state) when is_integer(ts) do
    if ANTime.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Override has expired.")
      %State{state | override: nil}
    else
      state
    end
  end

  defp maybe_clamp_movement(axis, old, new) do
    current = get_core_temp()
    upper = max_relative(current)
    lower = min_relative(current)

    cond do
      new > old && new > upper -> {:clamp, max(old, upper)}
      new < old && new < lower -> {:clamp, min(old, lower)}
      true -> {:ok, new}
    end
    |> then(fn
      {:clamp, temp} ->
        axis = ControlAxis.clamp(axis, temp_to_axis(temp), temp)
        {temp, axis}

      {:ok, temp} ->
        {temp, axis}
    end)
  end

  defp publish_core_temp(temp), do: PubSub.publish(:core_temp, {:core_temp, temp})

  @relative_low @temp_range.first + @clamp_near_boundary
  @relative_high @temp_range.last - @clamp_near_boundary

  defp min_relative(temp) when temp < @relative_low do
    # Half of the distance to the lower bound:
    temp - (temp - @temp_range.first) / 2
  end

  defp min_relative(temp), do: temp - @clamp_downwards

  defp max_relative(temp) when temp > @relative_high do
    # Half of the distance to the upper bound:
    temp + (@temp_range.last - temp) / 2
  end

  defp max_relative(temp), do: temp + @clamp_upwards

  defp get_future_pressure([]) do
    # No active loops, reactor idle.  Pretend current pressure is a bit too
    # high, so we slowly slew our target temperature towards the minimum.
    @target_pressure + @deadzone * 1.1
  end

  defp get_future_pressure(monitored) do
    monitored
    |> Enum.map(&MonitoredVessel.guess_future_pressure/1)
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
