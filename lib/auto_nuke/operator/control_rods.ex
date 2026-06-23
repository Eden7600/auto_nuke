defmodule AutoNuke.Operator.ControlRods do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:banks, :target, :axis, :last_temp]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @core API.Vessels.core_vessel()

  # Rods take time to move.  Try to keep our ordered rod height within 1% of actual.
  @rods_clamping 1.0

  def start_link(opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, target, opts)
  end

  def get_target(pid \\ __MODULE__), do: GenServer.call(pid, :get_target)
  def set_target(target, pid \\ __MODULE__), do: GenServer.call(pid, {:set_target, target})

  def get_rods(pid \\ __MODULE__), do: GenServer.call(pid, :get_rods)

  @impl true
  def init(target) when is_number(target) or is_nil(target) do
    {banks, rods} = get_banks_and_rods()
    bank_count = Enum.count(banks)

    temp = get_verified_core_temp([])
    target = target || temp

    axis =
      ControlAxis.new(
        kp: 0.05,
        ki: 0.005,
        kd: 0.01,
        deadzone: 0.5,
        to_value_fn: fn out -> axis_to_rods(out, bank_count) end,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        banks: banks,
        target: target,
        axis: axis,
        last_temp: temp
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
    temp = get_verified_core_temp([state.last_temp])

    case ControlAxis.step(state.axis, state.target, temp) do
      {:changed, axis, new, old} ->
        set_bank_rods(state.banks, old, new, state.target)
        maybe_clamp(state.banks, axis, new)

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn %ControlAxis{} = axis ->
      {:noreply, %State{state | axis: axis, last_temp: temp}}
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

  defp set_bank_rods(banks, old_rods, new_rods, target) do
    Enum.zip_with([banks, old_rods, new_rods], fn
      [_bank, same, same] ->
        same

      [bank, old, new] ->
        Logger.info(
          @log_prefix <>
            "Changing bank #{bank} rods #{old}% → #{new}% to reach #{Float.round(target, 2)}°C."
        )

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

  defp maybe_clamp(banks, axis, ordered) do
    actual = get_bank_rods(banks) |> Statistex.average()
    min_rods = actual - @rods_clamping
    max_rods = actual + @rods_clamping

    ordered = ordered |> Statistex.average()

    cond do
      ordered > max_rods ->
        # We're asking for too much rods at once, clamp down.
        Logger.debug(@log_prefix <> "Clamping down to #{max_rods}%.")
        axis |> ControlAxis.clamp(max_rods |> rods_to_axis())

      ordered < min_rods ->
        # We're asking for too little rods at once, clamp up.
        Logger.debug(@log_prefix <> "Clamping up to #{min_rods}%.")
        axis |> ControlAxis.clamp(min_rods |> rods_to_axis())

      true ->
        axis
    end
  end

  defp rods_to_axis(rods) when is_list(rods) do
    rods
    |> Statistex.average()
    |> rods_to_axis()
  end

  defp rods_to_axis(avg) when is_float(avg) do
    (50 - avg) / 50
  end
end
