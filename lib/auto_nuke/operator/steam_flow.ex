defmodule AutoNuke.Operator.SteamFlow do
  use GenServer
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Smoother

  defmodule State do
    # Give us the average of the last 5 ticks (1 sec) of generation:
    @generator_smoothing 5

    @enforce_keys [:axis, :limiters]
    defstruct(
      axis: nil,
      limiters: nil,
      smoothed_generation: Smoother.new(@generator_smoothing),
      target_override: nil
    )
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.Operator.SteamFlow.TorqueLimiter

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Valid loop numbers:
  @all_loops 1..3

  # Target 105% demand, plus or minus 5%.
  @target_percent 1.05
  @deadzone 0.05
  # But if resistor banks are on, drop that down to 95%, to try to avoid using them.
  @resistors_offset -0.10

  # When more power is needed, control MSCV between these values, using a
  # round-robin-increase distribution:
  @mscv_range 3..50
  @mscv_size (Range.size(@mscv_range) - 1) * Range.size(@all_loops)
  # When less power is needed, control turbine bypass between these values,
  # using raw control of all turbines at the same time:
  @bypass_range 0..80
  @bypass_size Range.size(@bypass_range) - 1
  # Assume that every 1 point of MSCV change is about 10 points of bypass:
  @mscv_bypass_ratio 10
  # Therefore, the transition point between bypass (low) and MSCV (high) is ...
  cutover_percent = @bypass_size / (@bypass_size + @mscv_size * @mscv_bypass_ratio)
  @axis_cutover_point cutover_percent * 2 - 1
  # Derived values for convenience:
  @axis_above_cutover 1.0 - @axis_cutover_point
  @axis_below_cutover @axis_cutover_point - -1.0

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def add_loop(loop, pid \\ __MODULE__) when loop in @all_loops do
    GenServer.call(pid, {:add, loop})
  end

  def remove_loop(loop, pid \\ __MODULE__) when loop in @all_loops do
    GenServer.call(pid, {:remove, loop})
  end

  def set_target_override(target, pid \\ __MODULE__) when is_number(target) and target < 10 do
    GenServer.cast(pid, {:override, target * 1.0})
  end

  def clear_target_override(pid \\ __MODULE__) do
    GenServer.cast(pid, {:override, nil})
  end

  @impl true
  def init(nil) do
    breakers = get_loop_breakers()
    connected = breakers |> Keyword.get_values(:closed)
    valves = get_valves()

    limiters =
      breakers
      |> Enum.map(fn
        {:open, _} -> nil
        {:closed, loop} -> TorqueLimiter.new(loop)
      end)

    axis =
      ControlAxis.new(
        kp: 0.1,
        ki: 0.01,
        kd: 0.005,
        deadzone: @deadzone,
        to_value_fn: &axis_to_valves/1,
        offset: valves |> valves_to_axis(connected),
        initial_value: valves
      )

    state = %State{
      limiters: limiters,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with loops #{inspect(connected)}.")
    {:ok, state}
  end

  @impl true
  def handle_call({:add, loop}, _from, %State{limiters: old_limiters} = state) do
    index = loop - 1

    case old_limiters |> Enum.at(index) do
      %TorqueLimiter{loop: ^loop} ->
        {:reply, {:error, :already_active}, state}

      nil ->
        new_limiters = old_limiters |> List.replace_at(index, TorqueLimiter.new(loop))
        {:reply, :ok, %State{state | limiters: new_limiters}}
    end
  end

  @impl true
  def handle_call({:remove, loop}, _from, %State{limiters: old_limiters} = state) do
    index = loop - 1

    case old_limiters |> Enum.at(index) do
      nil ->
        {:reply, {:error, :already_active}, state}

      %TorqueLimiter{loop: ^loop} ->
        new_limiters = old_limiters |> List.replace_at(index, nil)
        {:reply, :ok, %State{state | limiters: new_limiters}}
    end
  end

  @impl true
  def handle_cast({:override, nil}, %State{} = state) do
    Logger.notice(@log_prefix <> "Target override cleared.")
    {:reply, :ok, %State{state | target_override: nil}}
  end

  @impl true
  def handle_cast({:override, new}, %State{} = state) when is_float(new) do
    Logger.notice(@log_prefix <> "Target override set: #{percent(new)}")
    {:reply, :ok, %State{state | target_override: new}}
  end

  @impl true
  def handle_info({:tick, _}, %State{axis: axis} = state) do
    {ratio, %State{} = state} = get_demand_ratio(state)
    target = state.target_override || get_target_ratio()

    case ControlAxis.step(axis, target, ratio) do
      {:changed, axis, new, old} ->
        limiters = change_active_valves(state.limiters, old, new)
        %State{state | axis: axis, limiters: limiters}

      {:unchanged, axis, _old_value} ->
        limiters = state.limiters |> Enum.map(&TorqueLimiter.check_torque(&1))
        %State{state | axis: axis, limiters: limiters}
    end
    |> then(fn %State{} = new_state ->
      {:noreply, new_state}
    end)
  end

  defp get_demand_ratio(%State{smoothed_generation: smoothed} = state) do
    smoothed = smoothed |> Smoother.add(get_generation_kw(state))

    generated_kw = Smoother.average(smoothed)
    used_kw = API.get_float("POWER_FROM_TURBINE_KW")
    demand_kw = API.get_float("POWER_DEMAND_MW") * 1000
    ratio = (generated_kw - used_kw) / demand_kw

    {ratio, %State{state | smoothed_generation: smoothed}}
  end

  defp get_target_ratio do
    case API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH") do
      true -> @target_percent + @resistors_offset
      false -> @target_percent
    end
  end

  defp get_loop_breakers do
    @all_loops
    |> Enum.map(fn loop ->
      case API.get_boolean("GENERATOR_#{loop - 1}_BREAKER") do
        true -> {:open, loop}
        false -> {:closed, loop}
      end
    end)
  end

  defp get_generation_kw(%State{limiters: limiters}) do
    limiters
    |> Enum.map(fn %TorqueLimiter{loop: loop} ->
      API.get_float("GENERATOR_#{loop - 1}_KW")
    end)
    |> Enum.sum()
  end

  defp get_valves do
    @all_loops
    |> Enum.map(fn loop ->
      {get_bypass(loop), get_mscv(loop)}
    end)
  end

  defp get_bypass(loop), do: API.get_integer("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL")
  defp get_mscv(loop), do: API.get_integer("MSCV_#{loop - 1}_OPENING_ACTUAL")

  # Axis high: Bypass to zero, MSCV proportional within range.
  def axis_to_valves(output) when output >= @axis_cutover_point and output <= 1.0 do
    value = output - @axis_cutover_point
    percent = value / @axis_above_cutover

    @all_loops
    |> distribute(@mscv_size, percent)
    |> Enum.map(fn mscv -> {0, @mscv_range |> Enum.at(mscv)} end)
  end

  # Axis low: MSCV to minimum, bypass proportional within range.
  def axis_to_valves(output) when output >= -1.0 and output <= @axis_cutover_point do
    value = @axis_cutover_point - output
    bypass = (value / @axis_below_cutover * @bypass_size) |> round()

    min_mscv.._//1 = @mscv_range

    @all_loops
    |> Enum.map(fn _ -> {@bypass_range |> Enum.at(bypass), min_mscv} end)
  end

  # For n `items`, returns a list of length n where each value is between 0 and `size - 1`, based on `percent`.
  defp distribute(items, size, percent) do
    notches = round(size * percent)
    item_count = Enum.count(items)
    base = div(notches, item_count)
    remain = rem(notches, item_count)

    items
    |> Enum.with_index()
    |> Enum.map(fn {_, index} ->
      case index < remain do
        true -> base + 1
        false -> base
      end
    end)
  end

  def valves_to_axis(valves, connected_loops) do
    connected =
      valves
      |> Enum.with_index(1)
      |> Enum.filter(fn {_, index} -> index in connected_loops end)
      |> Enum.map(&elem(&1, 0))

    bypass =
      connected
      |> Enum.map(fn {b, _} -> b end)
      |> Statistex.average()
      |> percent_of_range(@bypass_range)

    mscv =
      connected
      |> Enum.map(fn {_, m} -> m end)
      |> Statistex.average()
      |> percent_of_range(@mscv_range)

    @axis_cutover_point - bypass * @axis_below_cutover + mscv * @axis_above_cutover
  end

  defp percent_of_range(value, rmin..rmax//1) do
    inside = value - rmin
    size = rmax - rmin

    (inside / size)
    |> max(0.0)
    |> min(1.0)
  end

  defp percent(float), do: "#{float * 100}%"

  defp change_active_valves(old_limiters, old_valves, new_valves) do
    Enum.zip_with([old_limiters, old_valves, new_valves], fn
      [nil, _, _] ->
        nil

      [%TorqueLimiter{} = limiter, old, new] ->
        Logger.info(@log_prefix <> "Changing valves from #{inspect(old)} to #{inspect(new)}.")
        limiter |> TorqueLimiter.set_valves(new)
    end)
  end
end
