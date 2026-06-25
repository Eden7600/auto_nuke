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
    @enforce_keys [:loop, :power_level, :max_power_level, :pressure]
    defstruct(@enforce_keys)
    alias __MODULE__, as: PL

    # Every power level is considered "worth" 2 bar of pressure.
    # So if we assign a power level to a turbine, we deduct 2 bar pressure.
    # If we take it away, it gains 2 bar.
    @power_cost 2
    # It's not an exact science, it's just meant 
    # to avoid taking the highest pressure loop 
    # and piling all the power onto it.

    @min_power_level Turbine.allowed_power_levels().first

    def at_min?(%PL{power_level: p}), do: p <= @min_power_level
    def at_max?(%PL{power_level: p, max_power_level: m}), do: p >= m

    def new(%Turbine{loop: loop} = turbine) do
      %PL{
        loop: loop,
        power_level: @min_power_level,
        max_power_level: Turbine.max_power_level(turbine),
        pressure: Turbine.guess_future_pressure(turbine)
      }
    end

    def add_power_level(%PL{power_level: old_power, pressure: old_pressure} = pl, amount)
        when is_integer(amount) and amount >= 1 do
      new_power =
        (old_power + amount)
        |> min(pl.max_power_level)
        |> max(@min_power_level)

      new_pressure = old_pressure - (new_power - old_power) * @power_cost

      %PL{pl | power_level: new_power, pressure: new_pressure}
    end

    def add_until_pressure(%PL{} = pl, 0, _), do: pl
    def add_until_pressure(%PL{pressure: p} = pl, _, p_limit) when p < p_limit, do: pl
    def add_until_pressure(%PL{power_level: max, max_power_level: max} = pl, _, _), do: pl

    def add_until_pressure(%PL{} = pl, amount, p_limit) do
      pl
      |> add_power_level(1)
      |> add_until_pressure(amount - 1, p_limit)
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
  # Ensure that all turbines produce at least 50 kg/min of steam between them.
  @min_steam 50

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
    GenServer.call(pid, :clear_override)
  end

  def get_target_override(pid \\ __MODULE__) do
    GenServer.call(pid, :get_override)
  end

  def get_power_levels(pid \\ __MODULE__) do
    GenServer.call(pid, :get_power_levels)
  end

  @impl true
  def init(nil) do
    connected = get_closed_breakers()
    count = Enum.count(connected)

    turbines = connected |> Enum.map(&Turbine.new/1)
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
        new_turbines =
          [Turbine.new(loop) | old_turbines]
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
        {:reply, :ok, %State{state | turbines: rest}}
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
  def handle_call(:clear_override, _false, %State{} = state) do
    Logger.notice(@log_prefix <> "Target override cleared.")
    {:reply, :ok, %State{state | target_override: nil}}
  end

  @impl true
  def handle_call(:get_override, _false, %State{target_override: override} = state) do
    {:reply, override, state}
  end

  @impl true
  def handle_call(:get_power_levels, _false, %State{turbines: turbines} = state) do
    {:reply, turbines |> Enum.map(& &1.power_level), state}
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
      {:changed, axis, new, _old} -> {axis, new}
      {:unchanged, axis, old} -> {axis, old}
    end
    |> then(fn {%ControlAxis{} = axis, value} ->
      turbine_count = Enum.count(old_turbines)
      total_power = axis_to_total_power(value, turbine_count)

      case update_power_levels(old_turbines, total_power) do
        {:ok, new_turbines} ->
          {axis, new_turbines}

        {:error, :at_max, max_total_power, new_turbines} ->
          max_axis = total_power_to_axis(max_total_power, turbine_count)
          {axis |> ControlAxis.clamp(max_axis), new_turbines}
      end
    end)
    |> then(fn {%ControlAxis{} = axis, turbines} ->
      {:noreply,
       %State{
         state
         | axis: axis,
           turbines:
             turbines
             |> distribute_min_steam()
             |> Enum.map(&Turbine.tick/1)
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

  def get_closed_breakers do
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
    power_levels = old_turbines |> Enum.map(&PowerLevel.new/1)
    current_total = power_levels |> Enum.sum_by(& &1.power_level)
    to_allocate = target_total - current_total

    new_power_levels = power_levels |> allocate_power(to_allocate)

    new_turbines =
      new_power_levels
      |> Enum.sort_by(& &1.loop)
      |> Enum.zip_with(old_turbines, fn
        %PowerLevel{loop: loop, power_level: power},
        %Turbine{loop: loop, power_level: power} = turbine ->
          # Power unchanged.
          turbine

        %PowerLevel{loop: loop, power_level: power}, %Turbine{loop: loop} = turbine ->
          turbine |> Turbine.set_power_level(power)
      end)

    new_total = new_power_levels |> Enum.sum_by(& &1.power_level)

    cond do
      new_total == target_total -> {:ok, new_turbines}
      new_total < target_total -> {:error, :at_max, new_total, new_turbines}
    end
  end

  # Nothing to allocate.
  defp allocate_power(power_levels, 0), do: power_levels

  # Single turbine case is very simple, just allocate whatever we can.
  defp allocate_power([%PowerLevel{} = old_pl], to_allocate) do
    new_pl = PowerLevel.add_power_level(old_pl, to_allocate)
    [new_pl]
  end

  defp allocate_power(power_levels, to_allocate) when to_allocate > 0 do
    {at_max, under_max} = power_levels |> Enum.split_with(&PowerLevel.at_max?/1)

    case under_max |> Enum.sort_by(& &1.pressure, :desc) do
      # Nothing left to allocate to.
      [] ->
        []

      # Just one, so use the one-item version above.
      [pl] ->
        allocate_power([pl], to_allocate)

      [old_first, second | rest] ->
        next_pressure = second.pressure
        new_first = old_first |> PowerLevel.add_until_pressure(to_allocate, next_pressure)
        allocated = new_first.power_level - old_first.power_level
        if allocated == 0, do: raise("infinite loop, should not happen")

        [new_first, second | rest]
        |> allocate_power(to_allocate - allocated)
    end
    |> then(fn new_under_max ->
      at_max ++ new_under_max
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

  @steam_gens API.SteamGen.all()

  defp distribute_min_steam([]), do: []

  defp distribute_min_steam(turbines) do
    count = Enum.count(turbines)
    managed_loops = turbines |> Enum.map(& &1.loop)

    unmanaged_steam =
      @steam_gens
      |> Enum.reject(&(&1.loop in managed_loops))
      |> Enum.sum_by(&API.SteamGen.get_outlet/1)

    remaining = (@min_steam - unmanaged_steam) |> max(0.0)
    per_turbine = remaining / count
    turbines |> Enum.map(&Turbine.set_min_steam(&1, per_turbine))
  end
end
