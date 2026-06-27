defmodule AutoNuke.Operator.ControlRods do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:banks, :target, :axis, :mode, :last_temp, :temp_history]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @core API.Vessels.core_vessel()

  # Rods take time to move.  Try to keep our ordered rod height within 1% of actual.
  @rods_clamping 1.0
  # Keep the last 10 temperature readings:
  @temp_history_size 10
  # Look ahead 5 more readings during control loop:
  @temp_lookahead 5

  @modes [:predictive, :direct]
  @default_mode :predictive

  def start_link(opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target)
    {mode, opts} = Keyword.pop(opts, :mode, @default_mode)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {target, mode}, opts)
  end

  def get_target(pid \\ __MODULE__), do: GenServer.call(pid, :get_target)

  def set_target(target, pid \\ __MODULE__) when is_number(target) do
    GenServer.call(pid, {:set_target, target + 0.0})
  end

  def set_mode(mode, pid \\ __MODULE__) when mode in @modes do
    GenServer.call(pid, {:set_mode, mode})
  end

  def get_rods(pid \\ __MODULE__), do: GenServer.call(pid, :get_rods)

  @impl true
  def init({target, mode}) when (is_number(target) or is_nil(target)) and mode in @modes do
    {banks, rods} = get_banks_and_rods()
    bank_count = Enum.count(banks)

    temp = get_verified_core_temp([])
    target = target || temp

    axis =
      ControlAxis.new(
        kp: 0.05,
        ki: 0.005,
        deadzone: 0.1,
        to_value_fn: fn out -> axis_to_rods(out, bank_count) end,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        banks: banks,
        target: target,
        axis: axis,
        mode: mode,
        last_temp: temp,
        temp_history: Smoother.new(@temp_history_size) |> Smoother.add(temp)
      }

    PubSub.subscribe(self(), :ticker)
    PubSub.subscribe(self(), :core_temp)

    Logger.info(
      @log_prefix <>
        "Started with core at #{temp}°C, target #{target}°C, rods at #{inspect(rods)}."
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_target, _from, %State{} = state) do
    {:reply, state.target, state}
  end

  @impl true
  def handle_call({:set_target, t}, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Target changed from #{state.target}°C to #{t}°C.")
    {:reply, :ok, %State{state | target: t}}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, %State{} = state) when mode in @modes do
    Logger.info(@log_prefix <> "Mode changed from '#{state.mode}' to '#{mode}'.")
    {:reply, :ok, %State{state | mode: mode}}
  end

  @impl true
  def handle_call(:get_rods, _from, %State{} = state) do
    banks_and_rods =
      state.banks
      |> Enum.zip(state.banks |> get_bank_rods())

    {:reply, banks_and_rods, state}
  end

  @impl true
  def handle_info({:core_temp, t}, %State{} = state) do
    {:noreply, %State{state | target: t}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    current_temp = get_verified_core_temp([state.last_temp])
    history = state.temp_history |> Smoother.add(current_temp)

    measurement =
      case state.mode do
        :predictive -> Smoother.extrapolate(history, @temp_lookahead)
        :direct -> current_temp
      end

    case ControlAxis.step(state.axis, state.target, measurement) do
      {:changed, axis, new, old} ->
        set_bank_rods(state.banks, old, new, current_temp, state.target)
        maybe_clamp(state.banks, axis, new)

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn %ControlAxis{} = axis ->
      {:noreply,
       %State{
         state
         | axis: axis,
           last_temp: current_temp,
           temp_history: history
       }}
    end)
  end

  def get_core_temp, do: API.Vessels.get_temperature(@core)

  # Avoid transients:
  defp get_verified_core_temp(seen) do
    temp = get_core_temp()

    if temp in seen do
      temp
    else
      Process.sleep(20)
      get_verified_core_temp([temp | seen])
    end
  end

  defp get_banks_and_rods do
    1..9
    |> Enum.map(fn n -> {n, API.get_float_or_nil("ROD_BANK_POS_#{n - 1}_ACTUAL")} end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.unzip()
  end

  defp get_bank_rods(banks) do
    banks
    |> Enum.map(fn n -> API.get_float("ROD_BANK_POS_#{n - 1}_ACTUAL") end)
  end

  defp set_bank_rods(banks, old_rods, new_rods, current_temp, target_temp) do
    Enum.zip_with([banks, old_rods, new_rods], fn
      [_bank, same, same] ->
        nil

      [bank, _old, new] ->
        API.put("ROD_BANK_POS_#{bank - 1}_ORDERED", new)
        {bank, new}
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn {_bank, rods} -> rods end)
    |> Enum.map(fn {rods, pairs} ->
      {rods,
       pairs
       |> Enum.map(fn {bank, _rods} -> bank end)
       |> Enum.sort()}
    end)
    |> Enum.sort_by(fn {_key, [head | _rest]} -> head end)
    |> Enum.map(fn {rods, banks} ->
      "#{rods}% (#{Enum.join(banks, "+")})"
    end)
    |> Enum.join(", ")
    |> then(fn desc ->
      Logger.info([
        @log_prefix,
        "Target #{format_temp(target_temp)}°C",
        " (#{format_delta(current_temp, target_temp)}°C).  Set ",
        desc,
        "."
      ])
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

  defp maybe_clamp(banks, axis, ordered) do
    actual = get_bank_rods(banks) |> Statistex.average()
    min_rods = actual - @rods_clamping
    max_rods = actual + @rods_clamping

    ordered = ordered |> Statistex.average()

    cond do
      # We're asking for too much rods at once, clamp down.
      ordered > max_rods -> {:down, max_rods}
      # We're asking for too little rods at once, clamp up.
      ordered < min_rods -> {:up, min_rods}
      true -> :as_is
    end
    |> then(fn
      {direction, bounds} ->
        Logger.debug(@log_prefix <> "Clamping #{direction} to #{Float.round(bounds, 1)}%.")
        output = bounds |> rods_to_axis()
        value = output |> axis_to_rods(Enum.count(banks))
        axis |> ControlAxis.clamp(output, value)

      :as_is ->
        axis
    end)
  end

  defp rods_to_axis(rods) when is_list(rods) do
    rods
    |> Statistex.average()
    |> rods_to_axis()
  end

  defp rods_to_axis(avg) when is_float(avg) do
    (50 - avg) / 50
  end

  defp format_delta(a, b) do
    delta = b - a
    str = format_temp(delta)
    if delta >= 0, do: "+#{str}", else: str
  end

  defp format_temp(temp), do: :erlang.float_to_binary(temp, decimals: 2)
end
