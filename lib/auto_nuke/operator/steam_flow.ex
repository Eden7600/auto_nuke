defmodule AutoNuke.Operator.SteamFlow do
  use GenServer
  require Logger

  alias AutoNuke.Smoother

  defmodule State do
    # Give us the average of the last 5 ticks (1 sec) of generation:
    @generator_smoothing 5

    @enforce_keys [:axis, :turbines]
    defstruct(
      axis: nil,
      turbines: nil,
      smoothed_generation: Smoother.new(@generator_smoothing),
      target_override: nil
    )
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis
  alias AutoNuke.Operator.SteamFlow.Turbine

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Valid loop numbers:
  @all_loops 1..3

  # Target 105% demand, plus or minus 5%.
  @target_percent 1.05
  @deadzone 0.05
  # But if resistor banks are on, drop that down to 95%, to try to avoid using them.
  @resistors_offset -0.10

  # There's no power level zero as far as we're concerned.
  @power_levels 1..100
  @power_level_span (Range.size(@power_levels) - 1) / 2
  # Ensure that all managed turbines produce at least 50 kg/min of steam between them.
  @min_steam 50
  defp steam_per_turbine(count) when count in 1..3, do: @min_steam / count

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
    connected = get_closed_breakers()
    count = Enum.count(connected)

    turbines = connected |> Enum.map(&Turbine.new(&1, steam_per_turbine(count)))
    initial = turbines |> Enum.sum_by(& &1.power_level) |> total_power_to_axis(count)

    axis =
      ControlAxis.new(
        kp: 0.1,
        ki: 0.01,
        kd: 0.005,
        deadzone: @deadzone,
        to_value_fn: &Function.identity/1,
        offset: initial,
        initial_value: initial
      )

    state = %State{
      turbines: turbines,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with loops #{inspect(connected)}.")
    {:ok, state}
  end

  @impl true
  def handle_call({:add, loop}, _from, %State{turbines: old_turbines} = state) do
    case old_turbines |> Enum.any?(&(&1.loop == loop)) do
      true ->
        {:reply, {:error, :already_active}, state}

      false ->
        steam =
          (Enum.count(old_turbines) + 1)
          |> steam_per_turbine()

        new_turbines =
          [
            Turbine.new(loop, steam)
            | old_turbines |> Enum.map(&Turbine.set_min_steam(&1, steam))
          ]
          |> Enum.sort_by(& &1.loop)

        {:reply, :ok, %State{state | turbines: new_turbines}}
    end
  end

  @impl true
  def handle_call({:remove, loop}, _from, %State{turbines: old_turbines} = state) do
    {found, rest} = old_turbines |> Enum.split_with(&(&1.loop == loop))

    case found do
      [] ->
        {:reply, {:error, :not_active}, state}

      [%Turbine{}] ->
        steam =
          Enum.count(rest)
          |> steam_per_turbine()

        new_turbines = rest |> Enum.map(&Turbine.set_min_steam(&1, steam))
        {:reply, :ok, %State{state | turbines: new_turbines}}
    end
  end

  @impl true
  def handle_cast({:override, nil}, %State{} = state) do
    Logger.notice(@log_prefix <> "Target override cleared.")
    {:noreply, %State{state | target_override: nil}}
  end

  @impl true
  def handle_cast({:override, new}, %State{} = state) when is_float(new) do
    Logger.notice(@log_prefix <> "Target override set: #{percent(new)}")
    {:noreply, %State{state | target_override: new}}
  end

  @impl true
  def handle_info({:tick, _}, %State{axis: old_axis, turbines: old_turbines} = state) do
    {ratio, smoother} = get_demand_ratio(state)
    target = state.target_override || get_target_ratio()

    case ControlAxis.step(old_axis, target, ratio) do
      {:changed, new_axis, new_value, _old_value} ->
        turbine_count = Enum.count(old_turbines)
        total_power = axis_to_total_power(new_value, turbine_count)

        case update_power_levels(old_turbines, total_power) do
          {:ok, new_turbines} ->
            {new_axis, new_turbines}

          {:error, :at_max, max_total_power, new_turbines} ->
            max_axis = total_power_to_axis(max_total_power, turbine_count)
            {new_axis |> ControlAxis.clamp_max(max_axis), new_turbines}
        end

      {:unchanged, new_axis, _old} ->
        {new_axis, old_turbines}
    end
    |> then(fn {%ControlAxis{} = axis, turbines} ->
      {:noreply,
       %State{
         state
         | axis: axis,
           turbines: turbines |> Enum.map(&Turbine.tick/1),
           smoothed_generation: smoother
       }}
    end)
  end

  defp get_demand_ratio(%State{smoothed_generation: smoothed} = state) do
    smoothed = smoothed |> Smoother.add(get_generation_kw(state))

    generated_kw = Smoother.average(smoothed)
    used_kw = API.get_float("POWER_FROM_TURBINE_KW")
    demand_kw = API.get_float("POWER_DEMAND_MW") * 1000
    ratio = (generated_kw - used_kw) / demand_kw

    {ratio, smoothed}
  end

  defp get_target_ratio do
    case API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH") do
      true -> @target_percent + @resistors_offset
      false -> @target_percent
    end
  end

  defp get_closed_breakers do
    @all_loops
    # true = open, false = closed
    |> Enum.reject(&API.get_boolean("GENERATOR_#{&1 - 1}_BREAKER"))
  end

  defp get_generation_kw(%State{turbines: turbines}) do
    turbines
    |> Enum.map(fn %Turbine{loop: loop} ->
      API.get_float("GENERATOR_#{loop - 1}_KW")
    end)
    |> Enum.sum()
  end

  defp percent(float), do: "#{float * 100}%"

  def total_power_to_axis(total, count) do
    total
    |> Kernel.-(@power_levels.first * count)
    |> Kernel./(@power_level_span * count)
    |> Kernel.-(1.0)
  end

  def axis_to_total_power(axis, count) do
    (axis + 1.0)
    |> Kernel.*(@power_level_span * count)
    |> round()
    |> Kernel.+(@power_levels.first * count)
  end

  defp update_power_levels(old_turbines, target_total) do
    power_levels =
      old_turbines
      |> Enum.map(fn %Turbine{} = t ->
        {t.loop, t.power_level, Turbine.max_power_level(t)}
      end)

    current_total = power_levels |> Enum.sum_by(fn {_, power, _} -> power end)

    if current_total == target_total do
      {:ok, old_turbines}
    else
      delta = target_total - current_total

      new_power_levels =
        allocate_power(power_levels, delta)
        |> Enum.sort()

      new_turbines =
        old_turbines
        |> Enum.zip_with(new_power_levels, fn
          %Turbine{loop: loop, power_level: power} = turbine, {loop, power, _max} ->
            # Power unchanged.
            turbine

          %Turbine{loop: loop} = turbine, {loop, power, _max} ->
            turbine |> Turbine.set_power_level(power)
        end)

      new_total = new_power_levels |> Enum.sum_by(fn {_, power, _} -> power end)

      cond do
        new_total == target_total -> {:ok, new_turbines}
        new_total < target_total -> {:error, :at_max, new_total, new_turbines}
      end
    end
  end

  defp allocate_power(power_levels, 0), do: power_levels

  # Single turbine case is very simple, just allocate whatever we can.
  defp allocate_power([{loop, old_power, max}], to_allocate) do
    new_power =
      (old_power + to_allocate)
      |> min(max)

    [{loop, new_power, max}]
  end

  defp allocate_power(power_levels, to_allocate) when to_allocate < 0 do
    power_levels
    |> Enum.sort_by(fn {_loop, power, max} ->
      # Over-max powers come first so we can lower them ASAP
      over_max_first = if power > max, do: 1, else: 2
      # Otherwise, sort by highest power first.
      {over_max_first, -power}
    end)
    |> then(fn
      [first, second | rest] ->
        {first_loop, old_first_power, first_max} = first
        {_, second_power, _} = second

        # Try to reduce as much power as we can,
        # ... but don't go lower than -1 below the next option,
        # ... unless our max is even lower than both of the above.
        new_first_power =
          (old_first_power + to_allocate)
          |> max(second_power - 1)
          |> min(first_max)

        new_power_levels = [
          {first_loop, new_first_power, first_max},
          second | rest
        ]

        to_allocate = to_allocate - (new_first_power - old_first_power)

        allocate_power(new_power_levels, to_allocate)
    end)
  end

  defp allocate_power(power_levels, to_allocate) when to_allocate > 0 do
    power_levels
    # Lowest power first, BUT maxed-out powers go last.
    |> Enum.sort_by(fn {_loop, power, max} ->
      # Under-max powers come first, we can't increase maxed out ones
      under_max_first = if power < max, do: 1, else: 2
      # Otherwise, sort by lowest power first.
      {under_max_first, power}
    end)
    |> then(fn
      [{_turbine, power, max} | _] when power >= max ->
        # Our best choice is already at max, so we can't allocate anything.
        power_levels

      [first, second | rest] ->
        {first_loop, old_first_power, first_max} = first
        {_, second_power, second_max} = second

        # Try to add as much power as we can,
        # ... but don't go over max,
        # ... and don't go more than +1 over the next option,
        #     UNLESS the next option (and thus, all other options) 
        #     are already at max.
        new_first_power =
          (old_first_power + to_allocate)
          |> min(first_max)
          |> then(fn v ->
            case second_power < second_max do
              true -> v |> min(second_power + 1)
              false -> v
            end
          end)

        new_power_levels = [
          {first_loop, new_first_power, first_max},
          second | rest
        ]

        to_allocate = to_allocate - (new_first_power - old_first_power)

        allocate_power(new_power_levels, to_allocate)
    end)
  end
end
