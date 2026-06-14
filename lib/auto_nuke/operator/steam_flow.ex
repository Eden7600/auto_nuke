defmodule AutoNuke.Operator.SteamFlow do
  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.Smoother
  alias AutoNuke.Operator.SteamFlow.{Turbine, DemandTracker}

  defmodule State do
    # Give us the average of the last 5 ticks of power generation:
    @supply_smoothing 5

    @enforce_keys [:axis, :turbines, :demand_tracker]
    defstruct(
      axis: nil,
      turbines: nil,
      demand_tracker: nil,
      smoothed_supply: Smoother.new(@supply_smoothing),
      target_override: nil
    )
  end

  defmodule PowerLevel do
    @enforce_keys [:loop, :capacity, :power_level, :max_power_level]
    defstruct(@enforce_keys)

    @min_power_level Turbine.allowed_power_levels().first

    def at_min?(%PowerLevel{power_level: p}), do: p <= @min_power_level
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

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Valid loop numbers:
  @loops 1..3

  # When overriding, use a flat 5% deadzone.
  @override_deadzone 0.05

  # Precalculate power level axis conversion factors:
  @power_levels Turbine.allowed_power_levels()
  @power_level_span (Range.size(@power_levels) - 1) / 2
  # Ensure that all managed turbines produce at least 50 kg/min of steam between them.
  @min_steam 50
  defp steam_per_turbine(count) when count in 1..3, do: @min_steam / count
  defp steam_per_turbine(0), do: 0.0

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
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

  def set_target_override(target, expiry \\ :next_hour, pid \\ __MODULE__)
      when is_number(target) do
    expires_at =
      case expiry do
        :never -> :never
        :next_hour -> get_next_hour()
        e -> AutoNuke.Time.parse_time(e)
      end

    GenServer.cast(pid, {:override, target / 100.0, expires_at})
  end

  def clear_target_override(pid \\ __MODULE__) do
    GenServer.cast(pid, :clear_override)
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
        # kd: 0.015,
        to_value_fn: &Function.identity/1,
        offset: initial,
        initial_value: initial
      )

    state = %State{
      turbines: turbines,
      axis: axis,
      demand_tracker: DemandTracker.new()
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
  def handle_cast(:clear_override, %State{} = state) do
    Logger.notice(@log_prefix <> "Target override cleared.")
    {:noreply, %State{state | target_override: nil}}
  end

  @impl true
  def handle_cast({:override, ratio, expiry}, %State{} = state) do
    expires_desc =
      case expiry do
        :never -> "does not expire"
        ts -> "expires at #{AutoNuke.Time.timestamp_to_string(ts)}"
      end

    Logger.notice(@log_prefix <> "Target set to #{percent(ratio)}, #{expires_desc}.")
    {:noreply, %State{state | target_override: {ratio, expiry}}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info(
        {:tick, _},
        %State{
          axis: %ControlAxis{} = old_axis,
          turbines: old_turbines
        } = state
      ) do
    supply_kw = get_current_supply(state.turbines)

    state =
      %State{
        state
        | demand_tracker: state.demand_tracker |> DemandTracker.tick(supply_kw),
          smoothed_supply: state.smoothed_supply |> Smoother.add(supply_kw)
      }
      |> maybe_expire_override()

    ratio = state.demand_tracker |> DemandTracker.current_ratio(supply_kw)
    {target, deadzone} = get_target_ratio_and_deadzone(state)
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
           turbines:
             turbines
             |> Enum.map(&Turbine.tick/1)
             |> publish_turbine_stats()
       }}
    end)
  end

  defp get_target_ratio_and_deadzone(%State{target_override: nil, demand_tracker: dt}),
    do: DemandTracker.target_and_deadzone(dt)

  defp get_target_ratio_and_deadzone(%State{target_override: {override, _}}),
    do: {override, @override_deadzone}

  defp get_current_supply(turbines) do
    turbines
    |> Enum.map(&Turbine.get_generated_power/1)
    |> Enum.sum()
    |> Kernel.-(API.Power.get_used_kw())
  end

  defp get_closed_breakers do
    @loops |> Enum.filter(&API.Generator.get_is_connected/1)
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
        # At-minimum powers come last, we can't lower those
        if(PowerLevel.at_min?(pl), do: 2, else: 1),
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

  defp maybe_expire_override(%State{target_override: nil} = state), do: state
  defp maybe_expire_override(%State{target_override: {_, :never}} = state), do: state

  defp maybe_expire_override(%State{target_override: {_, ts}} = state) when is_integer(ts) do
    if AutoNuke.Time.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Target override has expired.")
      %State{state | target_override: nil}
    else
      state
    end
  end

  defp get_next_hour do
    AutoNuke.Time.get_current_time()
    |> AutoNuke.Time.timestamp_to_tuple()
    |> then(fn
      {dd, 23, _mm} -> {dd + 1, 0, 0}
      {dd, hh, _mm} -> {dd, hh + 1, 0}
    end)
    |> AutoNuke.Time.parse_time()
  end

  defp publish_turbine_stats(turbines) do
    pressures = turbines |> Enum.map(fn %Turbine{pressure: p} -> p end)
    PubSub.publish(:steam_flow, {:steam_flow, pressures})
    turbines
  end
end
