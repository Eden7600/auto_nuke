defmodule AutoNuke.Operator.CoreFactor do
  use GenServer
  require Logger

  # Run on the first tick each second:
  defguard is_my_tick(t) when rem(t, 5) == 0

  defmodule State do
    @enforce_keys [:target, :axis, :smoothed, :last_core_factor]
    defstruct(
      target: nil,
      axis: nil,
      smoothed: nil,
      last_core_factor: nil,
      drift: nil
    )
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API
  alias AutoNuke.Smoother
  alias AutoNuke.Operator.CoreFactor.Drift

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Average the core factor over the past minute:
  @core_factor_smoothing AutoNuke.Ticker.ticks_per_minute()
  # Rods take time to move.  Try to keep our ordered rod height within 1% of actual.
  @rods_clamping 1.0

  def start_link(opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, target, opts)
  end

  def get_target(pid \\ __MODULE__) do
    GenServer.call(pid, :get_target)
  end

  def set_target(target, pid \\ __MODULE__) do
    GenServer.call(pid, {:set_target, target})
  end

  def drift(opts, pid \\ __MODULE__) do
    opts
    |> Keyword.put_new(:start_time, :now)
    |> Keyword.put_new_lazy(:start_factor, fn -> get_target(pid) end)
    |> Drift.new()
    |> then(&GenServer.call(pid, {:drift, &1}))
  end

  def stop_drift(pid \\ __MODULE__) do
    GenServer.call(pid, :stop_drift)
  end

  @impl true
  def init(target) when is_number(target) or is_nil(target) do
    rods = get_rods()
    factor = get_verified_core_factor([])
    target = target || factor

    axis =
      ControlAxis.new(
        kp: 0.02,
        ki: 0.002,
        deadzone: 0.01,
        to_value_fn: &axis_to_rods/1,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        target: target,
        axis: axis,
        smoothed: Smoother.new(@core_factor_smoothing),
        last_core_factor: factor
      }

    PubSub.subscribe(self(), :ticker)

    Logger.info(
      @log_prefix <> "Started with core factor #{factor}, target #{target}, rods at #{rods}%."
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_target, _from, %State{} = state) do
    {:reply, state.target, state}
  end

  @impl true
  def handle_call({:set_target, t}, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Core factor target changed from #{state.target} to #{t}.")
    {:reply, :ok, %State{state | target: t}}
  end

  @impl true
  def handle_call({:drift, drift}, _from, %State{} = state) do
    Logger.info([
      @log_prefix,
      "Now planning to drift from #{drift.start_factor} at ",
      Drift.timestamp_to_string(drift.start_time),
      " to #{drift.end_factor} at ",
      Drift.timestamp_to_string(drift.end_time),
      "."
    ])

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
    state = tick_drift(state)

    factor = get_verified_core_factor([state.last_core_factor])
    smoothed = state.smoothed |> Smoother.add(factor)
    current = Smoother.average(smoothed)

    case ControlAxis.step(state.axis, state.target, current) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing rods from #{old} to #{new}.")
        set_rods(new)
        maybe_clamp(axis, new)

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis, smoothed: smoothed, last_core_factor: factor}}
    end)
  end

  defp tick_drift(%State{drift: nil} = state), do: state

  defp tick_drift(%State{drift: {drift, started}} = state) do
    case Drift.current_value(drift) do
      :not_started ->
        state

      {:complete, target} ->
        Logger.notice(@log_prefix <> "Drift completed, target is now #{target}.")
        %State{state | target: target, drift: nil}

      {:drifting, target} ->
        case started do
          true ->
            %State{state | target: target}

          false ->
            Logger.notice(
              @log_prefix <>
                "Beginning drift from #{drift.start_factor} to #{drift.end_factor} ..."
            )

            %State{state | target: target, drift: {drift, true}}
        end
    end
  end

  # Avoid transients:
  defp get_verified_core_factor(seen) do
    factor = get_core_factor()

    if factor in seen do
      factor
    else
      Process.sleep(20)
      get_verified_core_factor([factor | seen])
    end
  end

  def get_core_factor, do: API.get_float("CORE_FACTOR")
  defp get_rods, do: API.get_float("RODS_POS_ACTUAL")

  defp set_rods(value) when value >= 0.0 and value <= 100.0,
    do: API.put("RODS_ALL_POS_ORDERED", value)

  defp axis_to_rods(output), do: (50 - output * 50) |> Float.round(1)
  defp rods_to_axis(rods), do: (50 - rods) / 50

  defp maybe_clamp(axis, ordered) do
    actual = get_rods()

    cond do
      ordered - actual > @rods_clamping ->
        # We're asking for too much rods at once, clamp down.
        Logger.debug(@log_prefix <> "Clamping down to #{actual + @rods_clamping}")
        clamp_to = (actual + @rods_clamping) |> rods_to_axis()
        axis |> ControlAxis.clamp_min(clamp_to)

      actual - ordered > @rods_clamping ->
        # We're asking for too little rods at once, clamp up.
        Logger.debug(@log_prefix <> "Clamping up to #{actual - @rods_clamping}")
        clamp_to = (actual - @rods_clamping) |> rods_to_axis()
        axis |> ControlAxis.clamp_max(clamp_to)

      true ->
        axis
    end
  end
end
