defmodule AutoNuke.Operator.SteamFlow do
  use GenServer
  require Logger

  alias AutoNuke.Smoother
  alias AutoNuke.Operator.SteamFlow.Turbine

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

  defmodule PowerLevel do
    @enforce_keys [:loop, :capacity, :power_level, :max_power_level]
    defstruct(@enforce_keys)

    @min_power_level Turbine.allowed_power_levels().first

    def at_max?(%PowerLevel{power_level: p, max_power_level: m}), do: p >= m
    def power_ratio(%PowerLevel{capacity: c, power_level: p}), do: p / c

    def change_power_level(%PowerLevel{} = pl, change) do
      new_power =
        (pl.power_level + change)
        |> min(pl.max_power_level)
        |> max(@min_power_level)

      %PowerLevel{pl | power_level: new_power}
    end
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Valid loop numbers:
  @all_loops 1..3

  # Unless overridden, we target between 95% and 110% demand.
  #
  # Why 95%?  Because if demand increases, there will be a brief period
  # at the start of the hour where we're underproducing, and if we then
  # happen to end up at just over 90% the rest of the hour, we might still
  # miss the 90% demand target.
  #
  # To accomplish this, we target 102.5%, plus or minus 7.5%.
  @target_percent 1.025
  @deadzone 0.075
  # When overriding, use a flat 5% deadzone.
  @override_deadzone 0.05

  # Precalculate power level axis conversion factors:
  @power_levels Turbine.allowed_power_levels()
  @power_level_span (Range.size(@power_levels) - 1) / 2
  # Ensure that all managed turbines produce at least 50 kg/min of steam between them.
  @min_steam 50
  defp steam_per_turbine(count) when count in 1..3, do: @min_steam / count

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def add_loop(loop, pid \\ __MODULE__) when loop in @all_loops do
    GenServer.call(pid, {:add_loop, loop})
  end

  def remove_loop(loop, pid \\ __MODULE__) when loop in @all_loops do
    GenServer.call(pid, {:remove_loop, loop})
  end

  def get_loops(pid \\ __MODULE__) do
    GenServer.call(pid, :get_loops)
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
        kp: 0.3,
        ki: 0.03,
        kd: 0.015,
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
  def handle_call({:add_loop, loop}, _from, %State{turbines: old_turbines} = state) do
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
  def handle_call({:remove_loop, loop}, _from, %State{turbines: old_turbines} = state) do
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
  def handle_call(:get_loops, _from, %State{turbines: old_turbines} = state) do
    old_turbines
    |> Enum.map(& &1.loop)
    |> then(fn loops ->
      {:reply, loops, state}
    end)
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
  def handle_info(
        {:tick, _},
        %State{
          axis: %ControlAxis{} = old_axis,
          turbines: old_turbines
        } = state
      ) do
    {ratio, smoother} = get_demand_ratio(state)
    {target, deadzone} = get_target_ratio_and_deadzone(state.target_override)
    old_axis = %ControlAxis{old_axis | deadzone: deadzone}

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

  defp get_target_ratio_and_deadzone(nil), do: {@target_percent, @deadzone}

  defp get_target_ratio_and_deadzone(override) when is_float(override),
    do: {override, @override_deadzone}

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

  def total_power_to_axis(_, 0), do: -1.0

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
        %PowerLevel{
          loop: t.loop,
          capacity: t.primary_capacity,
          power_level: t.power_level,
          max_power_level: Turbine.max_power_level(t)
        }
      end)

    current_total = power_levels |> Enum.sum_by(& &1.power_level)

    if current_total == target_total do
      {:ok, old_turbines}
    else
      delta = target_total - current_total

      new_power_levels =
        allocate_power(power_levels, delta)
        |> Enum.sort_by(& &1.loop)

      new_turbines =
        old_turbines
        |> Enum.zip_with(new_power_levels, fn
          %Turbine{loop: loop, power_level: power} = turbine,
          %PowerLevel{loop: loop, power_level: power} ->
            # Power unchanged.
            turbine

          %Turbine{loop: loop} = turbine, %PowerLevel{loop: loop, power_level: power} ->
            turbine |> Turbine.set_power_level(power)
        end)

      new_total = new_power_levels |> Enum.sum_by(& &1.power_level)

      cond do
        new_total == target_total -> {:ok, new_turbines}
        new_total < target_total -> {:error, :at_max, new_total, new_turbines}
      end
    end
  end

  defp allocate_power(power_levels, 0), do: power_levels

  # Single turbine case is very simple, just allocate whatever we can.
  defp allocate_power([%PowerLevel{} = old_pl], to_allocate) do
    new_pl = PowerLevel.change_power_level(old_pl, to_allocate)
    [new_pl]
  end

  defp allocate_power(power_levels, to_allocate) when to_allocate < 0 do
    power_levels
    |> Enum.sort_by(fn %PowerLevel{} = pl ->
      {
        # Over-max powers come first so we can lower them ASAP
        if(PowerLevel.at_max?(pl), do: 1, else: 2),
        # Otherwise, sort by highest power ratio first.
        -PowerLevel.power_ratio(pl)
      }
    end)
    |> then(fn [old_pl | rest] ->
      new_pl = PowerLevel.change_power_level(old_pl, -1)
      new_power_levels = [new_pl | rest]

      if new_pl.power_level == old_pl.power_level do
        # Can't reduce anything, give up.
        new_power_levels
      else
        allocate_power([new_pl | rest], to_allocate + 1)
      end
    end)
  end

  defp allocate_power(power_levels, to_allocate) when to_allocate > 0 do
    power_levels
    # Lowest power ratio first, BUT maxed-out powers go last.
    |> Enum.sort_by(fn pl ->
      {
        # Under-max powers come first, we can't increase maxed out ones
        if(PowerLevel.at_max?(pl), do: 2, else: 1),
        # Otherwise, sort by lowest power ratio first.
        PowerLevel.power_ratio(pl)
      }
    end)
    |> then(fn [old_pl | rest] ->
      if PowerLevel.at_max?(old_pl) do
        # Can't increase anything.
        power_levels
      else
        new_pl = PowerLevel.change_power_level(old_pl, +1)

        if new_pl.power_level == old_pl.power_level do
          raise "Can't increase power level: #{inspect(old_pl)}"
        end

        allocate_power([new_pl | rest], to_allocate - 1)
      end
    end)
  end
end
