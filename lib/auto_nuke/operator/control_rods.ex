defmodule AutoNuke.Operator.ControlRods do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:banks, :target, :axis, :mode, :last_temp, :last_rods, :temp_history]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @core API.Vessels.core_vessel()
  @all_banks 1..9

  # Rods take time to move.  Try to keep our ordered rod height within 1% of actual.
  @rods_clamping 1.0

  # Anti-hunting: ignore published target changes smaller than this (the
  # pressure PID upstream jitters at 0.01°C granularity)...
  @target_hysteresis 0.1
  # ...and while within this range of target, don't issue rod commands
  # smaller than @min_move — let the intent accumulate into one real move.
  @calm_zone 0.8
  @min_move 0.5
  # Keep the last 10 temperature readings:
  @temp_history_size 10
  # Look ahead 5 more readings during control loop:
  @temp_lookahead 5

  @modes [:predictive, :direct]
  @default_mode Enum.at(@modes, 0)

  def start_link(opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target)
    {mode, opts} = Keyword.pop(opts, :mode, @default_mode)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {target, mode}, opts)
  end

  def get_target(pid \\ __MODULE__), do: GenServer.call(pid, :get_target)

  def get_mode(pid \\ __MODULE__) do
    GenServer.call(pid, :get_mode)
  end

  def set_mode(mode, pid \\ __MODULE__) when mode in @modes do
    GenServer.call(pid, {:set_mode, mode})
  end

  def get_rods(pid \\ __MODULE__), do: GenServer.call(pid, :get_rods)

  def add_bank(bank, pid \\ __MODULE__) when bank in @all_banks,
    do: GenServer.call(pid, {:add_bank, bank})

  def remove_bank(bank, pid \\ __MODULE__) when bank in @all_banks,
    do: GenServer.call(pid, {:remove_bank, bank})

  @impl true
  def init({target, mode}) when (is_number(target) or is_nil(target)) and mode in @modes do
    {banks, rods} = get_installed_banks_and_rods()

    temp = get_verified_core_temp([])
    target = target || temp
    boron? = using_boron?()

    axis =
      ControlAxis.new(
        kp: if(boron?, do: 0.05, else: 0.0005),
        ki: if(boron?, do: 0.005, else: 0.00005),
        deadzone: 1.0,
        to_value_fn: &Function.identity/1,
        offset: rods |> rods_to_axis(),
        initial_value: rods |> rods_to_axis()
      )

    state =
      %State{
        banks: banks,
        target: target,
        axis: axis,
        mode: mode,
        last_temp: temp,
        last_rods: rods,
        temp_history: Smoother.new(@temp_history_size) |> Smoother.add(temp)
      }

    PubSub.subscribe(self(), :ticker)
    PubSub.subscribe(self(), :core_temp)

    Logger.info([
      @log_prefix,
      "Started in #{mode} mode",
      " with core at #{temp}°C,",
      " target #{target}°C,",
      " rods at #{inspect(rods)}."
    ])

    {:ok, state}
  end

  @impl true
  def handle_call(:get_target, _from, %State{} = state) do
    {:reply, state.target, state}
  end

  @impl true
  def handle_call(:get_mode, _from, %State{} = state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, %State{} = state) when mode in @modes do
    Logger.info(@log_prefix <> "Mode changed from '#{state.mode}' to '#{mode}'.")
    {:reply, :ok, %State{state | mode: mode}}
  end

  @impl true
  def handle_call(:get_rods, _from, %State{} = state) do
    banks_and_rods = Enum.zip(state.banks, state.last_rods)
    {:reply, banks_and_rods, state}
  end

  @impl true
  def handle_call({:add_bank, bank}, _from, %State{} = state) do
    bank_rods = maybe_get_bank_rods(bank)

    cond do
      bank in state.banks ->
        {:reply, {:error, :already_managed}, state}

      is_nil(bank_rods) ->
        {:reply, {:error, :not_installed}, state}

      true ->
        {banks, rods} =
          Enum.zip(
            [bank | state.banks],
            [bank_rods | state.last_rods]
          )
          |> Enum.sort()
          |> Enum.unzip()

        axis = state.axis |> ControlAxis.clamp(rods_to_axis(rods))

        {:reply, :ok, %State{state | banks: banks, last_rods: rods, axis: axis}}
    end
  end

  @impl true
  def handle_call({:remove_bank, bank}, _from, %State{} = state) do
    if bank in state.banks do
      {banks, rods} =
        Enum.zip(state.banks, state.last_rods)
        |> Enum.reject(fn {b, _} -> b == bank end)
        |> Enum.unzip()

      {:reply, :ok, %State{state | banks: banks, last_rods: rods}}
    else
      {:reply, {:error, :not_managed}, state}
    end
  end

  @impl true
  def handle_info({:core_temp, t}, %State{} = state) do
    if abs(t - state.target) >= @target_hysteresis do
      {:noreply, %State{state | target: t}}
    else
      {:noreply, state}
    end
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
      {:changed, axis, new, _old} -> {new, axis}
      {:unchanged, axis, old} -> {old, axis}
    end
    |> then(fn {value, %ControlAxis{} = axis} ->
      new_rods = axis_to_rods(value, Enum.count(state.banks))
      {applied_rods, changes} = gate_rod_command(state, measurement, new_rods)

      changes
      |> log_rod_changes(current_temp, state.target)
      |> set_bank_rods()

      {:noreply,
       %State{
         state
         | axis: maybe_clamp(axis, state.banks, applied_rods),
           last_temp: current_temp,
           last_rods: applied_rods,
           temp_history: history
       }}
    end)
  end

  # Anti-hunting gate: near the target, sub-@min_move commands are held —
  # the axis keeps its intent (bounded by @rods_clamping), and only a move
  # worth making is issued. Real deviations behave exactly as before.
  defp gate_rod_command(%State{} = state, measurement, new_rods) do
    calm? = abs(state.target - measurement) <= @calm_zone

    small? =
      state.last_rods != [] and new_rods != [] and
        abs(Statistex.average(new_rods) - Statistex.average(state.last_rods)) < @min_move

    if calm? and small? and new_rods != state.last_rods do
      Logger.debug(@log_prefix <> "Holding rods (calm zone, move under #{@min_move}%).")
      {state.last_rods, []}
    else
      {new_rods, calculate_rod_changes(state.banks, state.last_rods, new_rods)}
    end
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

  defp get_installed_banks_and_rods do
    @all_banks
    |> Enum.map(fn b ->
      {b, maybe_get_bank_rods(b)}
    end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.unzip()
  end

  defp get_bank_rods(n), do: API.get_float("ROD_BANK_POS_#{n - 1}_ACTUAL")
  defp maybe_get_bank_rods(n), do: API.get_float_or_nil("ROD_BANK_POS_#{n - 1}_ACTUAL")

  defp calculate_rod_changes(banks, old_rods, new_rods) do
    Enum.zip([banks, old_rods, new_rods])
    |> Enum.filter(fn
      {_bank, same, same} -> false
      {_bank, _old, _new} -> true
    end)
  end

  defp log_rod_changes([], _, _), do: []

  defp log_rod_changes(rod_changes, current_temp, target_temp) do
    rod_changes
    |> Enum.group_by(fn {_bank, _old, new} -> new end)
    |> Enum.map(fn {value, pairs} ->
      {value,
       pairs
       |> Enum.map(fn {bank, _old, _new} -> bank end)}
    end)
    |> Enum.sort_by(fn {_key, [first | _rest]} -> first end)
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

    rod_changes
  end

  defp set_bank_rods(rod_changes) do
    rod_changes
    |> Enum.each(fn {bank, _old, new} ->
      API.put("ROD_BANK_POS_#{bank - 1}_ORDERED", new)
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

  defp maybe_clamp(axis, banks, new_rods) do
    ordered = new_rods |> Statistex.average()
    actual = banks |> Enum.map(&get_bank_rods/1) |> Statistex.average()

    min_rods = actual - @rods_clamping
    max_rods = actual + @rods_clamping

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
        axis |> ControlAxis.clamp(output)

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

  defp using_boron?, do: API.get_float("CHEM_BORON_PPM") > 0.0
end
