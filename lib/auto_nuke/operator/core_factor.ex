defmodule AutoNuke.Operator.CoreFactor do
  use GenServer
  require Logger

  # Run on the first tick each second:
  @ticks_per_second AutoNuke.Ticker.ticks_per_second()
  defguard is_my_tick(t) when rem(t, @ticks_per_second) == 0

  defmodule State do
    @enforce_keys [:banks, :target, :axis, :smoothed, :last_core_factor]
    defstruct(
      banks: nil,
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

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Average the core factor over the past minute:
  @core_factor_smoothing AutoNuke.Ticker.seconds_per_minute()

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
    {banks, rods} = get_banks_and_rods()
    bank_count = Enum.count(banks)

    factor = get_verified_core_factor([])
    target = target || factor

    axis =
      ControlAxis.new(
        kp: 0.02,
        ki: 0.002,
        deadzone: 0.01,
        to_value_fn: fn out -> axis_to_rods(out, bank_count) end,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        banks: banks,
        target: target,
        axis: axis,
        smoothed: Smoother.new(@core_factor_smoothing),
        last_core_factor: factor
      }

    PubSub.subscribe(self(), :ticker)

    Logger.info(
      @log_prefix <>
        "Started with core factor #{factor}, target #{target}, rods at #{inspect(rods)}."
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
        set_bank_rods(state.banks, old, new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn %ControlAxis{} = axis ->
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

  defp get_banks_and_rods do
    1..9
    |> Enum.map(fn n -> {n, API.get_float_or_nil("ROD_BANK_POS_#{n - 1}_ACTUAL")} end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.unzip()
  end

  defp set_bank_rods(banks, old_rods, new_rods) do
    Enum.zip_with([banks, old_rods, new_rods], fn
      [_bank, same, same] ->
        same

      [bank, old, new] ->
        Logger.info(@log_prefix <> "Changing bank #{bank} rods from #{old} to #{new}.")
        API.put("ROD_BANK_POS_#{bank - 1}_ORDERED", new)
        new
    end)
  end

  def axis_to_rods(output, bank_count) do
    # Map -1.0 to 100% rods and +1.0 to 0% rods.
    raw = 50 - output * 50

    # Every bank will receive this base value at 0.1 precision,
    # but some may receive +0.1.
    base = Float.floor(raw, 1)
    remain = raw - base
    span = 0.1 / bank_count

    1..bank_count
    |> Enum.map(fn bank ->
      case bank * span < remain do
        true -> (base + 0.1) |> Float.round(1)
        false -> base
      end
    end)
  end

  defp rods_to_axis(rods) do
    avg = rods |> Statistex.average()
    (50 - avg) / 50
  end
end
