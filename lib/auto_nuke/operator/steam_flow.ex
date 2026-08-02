defmodule AutoNuke.Operator.SteamFlow do
  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.Operator.SteamFlow.{Turbine, DemandTracker}
  alias AutoNuke.Time, as: ANTime

  defmodule State do
    @enforce_keys [:axis, :turbines, :demand_tracker, :target_override]
    defstruct(
      axis: nil,
      turbines: nil,
      demand_tracker: nil,
      target_override: nil,
      boost_mode: nil,
      flow_control: nil,
      # Demand debounce (feedforward fires only on confirmed changes):
      stable_demand: nil,
      pending_demand: nil
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

    def new(%Turbine{loop: loop} = turbine, boost_mode) do
      %PL{
        loop: loop,
        power_level: @min_power_level,
        max_power_level: Turbine.max_power_level(turbine, boost_mode),
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
  @min_steam 55

  def start_link(opts \\ []) do
    {loops, opts} = Keyword.pop(opts, :loops, :detect)
    {override, opts} = Keyword.pop(opts, :override)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {loops, override}, opts)
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

  def set_target_override_percent(p, expiry \\ :next_hour, pid \\ __MODULE__)
      when is_number(p) do
    GenServer.call(pid, {:override, {p / 100.0, :ratio}, ANTime.parse_expiry(expiry)})
  end

  def set_target_override_mw(mw, expiry \\ :next_hour, pid \\ __MODULE__)
      when is_number(mw) do
    GenServer.call(pid, {:override, {mw, :mw}, ANTime.parse_expiry(expiry)})
  end

  def clear_target_override(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_override)
  end

  def get_target_override(pid \\ __MODULE__) do
    GenServer.call(pid, :get_override)
  end

  def enable_boost_mode(expiry \\ :next_hour, pid \\ __MODULE__) do
    GenServer.call(pid, {:boost_mode, ANTime.parse_expiry(expiry)})
  end

  def disable_boost_mode(pid \\ __MODULE__) do
    GenServer.call(pid, {:boost_mode, nil})
  end

  def get_power_levels(pid \\ __MODULE__) do
    GenServer.call(pid, :get_power_levels)
  end

  def get_demand_status(pid \\ __MODULE__) do
    GenServer.call(pid, :get_demand_status)
  end

  def get_boost_mode(pid \\ __MODULE__) do
    GenServer.call(pid, :get_boost_mode)
  end

  def set_generated_mwh(mwh, pid \\ __MODULE__) do
    GenServer.call(pid, {:set_generated_mwh, mwh})
  end

  @impl true
  def init({loops, override}) do
    loops =
      case loops do
        :detect -> get_closed_breakers()
        l when is_list(l) -> Enum.sort(l)
      end

    count = Enum.count(loops)

    turbines = loops |> Enum.map(&Turbine.new/1)
    total_power = turbines |> Enum.sum_by(& &1.power_level)
    initial = total_power |> total_power_to_axis(count)

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
      demand_tracker: DemandTracker.new(),
      target_override:
        case override do
          nil -> nil
          {_, _} = o -> {o, :never}
        end
    }

    PubSub.subscribe(self(), :ticker)
    PubSub.subscribe(self(), :steam_flow_control)

    Logger.info([
      @log_prefix,
      "Started with loops ",
      inspect(loops),
      ", total power #{total_power}",
      case override do
        nil -> ""
        {_, _} -> ", overriding to #{describe_override(override)}"
      end,
      "."
    ])

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

      [%Turbine{loop: ^loop}] ->
        {:reply, :ok, %State{state | turbines: rest}}
    end
  end

  @impl true
  def handle_call(:get_loops, _from, %State{turbines: turbines} = state) do
    turbines
    |> Enum.map(& &1.loop)
    |> then(fn loops ->
      {:reply, loops, state}
    end)
  end

  @impl true
  def handle_call({:override, override, expiry}, _from, %State{} = state) do
    Logger.notice([
      @log_prefix,
      "Target set to ",
      describe_override(override),
      ", ",
      describe_expiry(expiry),
      "."
    ])

    {:reply, :ok, %State{state | target_override: {override, expiry}}}
  end

  @impl true
  def handle_call(:clear_override, _from, %State{} = state) do
    Logger.notice(@log_prefix <> "Target override cleared.")
    {:reply, :ok, %State{state | target_override: nil}}
  end

  @impl true
  def handle_call(:get_override, _from, %State{target_override: override} = state) do
    {:reply, override, state}
  end

  @impl true
  def handle_call(:get_power_levels, _from, %State{turbines: turbines} = state) do
    {:reply, turbines |> Enum.map(& &1.power_level), state}
  end

  @impl true
  def handle_call(:get_demand_status, _from, %State{} = state) do
    {target, _deadzone} = get_target_ratio_and_deadzone(state)

    status =
      state.demand_tracker
      |> DemandTracker.status()
      |> Map.merge(%{
        target: target,
        override?: state.target_override != nil,
        boost?: state.boost_mode != nil,
        power_levels: state.turbines |> Enum.map(& &1.power_level)
      })

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_boost_mode, _from, %State{boost_mode: boost} = state) do
    {:reply, boost, state}
  end

  @impl true
  def handle_call({:boost_mode, expiry}, _from, %State{} = state) do
    desc =
      case expiry do
        nil -> "disabled"
        :never -> "enabled, no expiry"
        ts -> "enabled until #{ANTime.timestamp_to_string(ts)}"
      end

    Logger.notice(@log_prefix <> "Boost mode #{desc}.")
    {:reply, :ok, %State{state | boost_mode: expiry}}
  end

  @impl true
  def handle_call({:set_generated_mwh, mwh}, _from, %State{demand_tracker: tracker} = state) do
    tracker = tracker |> DemandTracker.set_supplied_kwh(mwh * 1000)
    result = tracker |> DemandTracker.target_and_deadzone()
    {:reply, result, %State{state | demand_tracker: tracker}}
  end

  @impl true
  def handle_info({:steam_flow_control, :resume}, %State{} = state) do
    if state.flow_control do
      Logger.notice(@log_prefix <> "Flow control disabled.")
    end

    {:noreply, %State{state | flow_control: nil}}
  end

  @impl true
  def handle_info({:steam_flow_control, :hold}, %State{} = state) do
    new_flow_control = current_flow_limited_power(state)

    if state.flow_control != new_flow_control do
      Logger.notice(@log_prefix <> "Flow control: Holding at #{new_flow_control}.")
    end

    {:noreply, %State{state | flow_control: new_flow_control}}
  end

  @impl true
  def handle_info({:steam_flow_control, :backoff}, %State{} = state) do
    new_flow_control = current_flow_limited_power(state) - 1

    if state.flow_control != new_flow_control do
      Logger.notice(@log_prefix <> "Flow control: Backing off to #{new_flow_control}.")
    end

    {:noreply, %State{state | flow_control: new_flow_control}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{turbines: turbines} = state) do
    supply_kw = get_current_supply(turbines)

    state =
      %State{
        state
        | demand_tracker: state.demand_tracker |> DemandTracker.tick(supply_kw)
      }
      |> maybe_expire_override()
      |> maybe_expire_boost_mode()

    {stable, pending, confirmed} =
      debounce_demand(state.stable_demand, state.pending_demand, state.demand_tracker.demand_kwh)

    state = %State{state | stable_demand: stable, pending_demand: pending}

    if turbines |> Enum.all?(&Turbine.sanity_check/1) do
      tick_power(state, supply_kw, confirmed)
    else
      state
    end
    |> then(fn %State{} = s -> {:noreply, s} end)
  end

  # How different two demand readings must be to count as a change:
  @demand_change_threshold 0.005

  @doc """
  Demand-change debouncing: a new demand level must hold for two
  consecutive ticks before it's confirmed — a single-tick blip from the
  game must not whipsaw the feedforward.

  Returns `{stable, pending, confirmed}` where `confirmed` is
  `{old, new}` on the tick a change is accepted, else nil.
  """
  def debounce_demand(nil, _pending, new), do: {new, nil, nil}

  def debounce_demand(stable, pending, new) do
    cond do
      demand_close?(new, stable) -> {stable, nil, nil}
      pending != nil and demand_close?(new, pending) -> {new, nil, {stable, new}}
      true -> {stable, new, nil}
    end
  end

  defp demand_close?(a, b) do
    b > 0 and abs(a - b) / b < @demand_change_threshold
  end

  defp tick_power(
         %State{
           axis: %ControlAxis{} = old_axis,
           turbines: old_turbines
         } = state,
         supply_kw,
         confirmed_demand_change
       ) do
    ratio = state.demand_tracker |> DemandTracker.current_ratio(supply_kw)
    {target, deadzone} = get_target_ratio_and_deadzone(state)
    old_axis = %ControlAxis{old_axis | deadzone: deadzone}
    old_axis = maybe_feedforward(old_axis, state, confirmed_demand_change, target, supply_kw)
    boost_mode = !is_nil(state.boost_mode)

    # Limit the new target to within +20% of our current ratio.  If we just
    # can't produce enough, period, then our target will get exponentially
    # further and further out of reach.  Then, the next hour comes around, and
    # BAM our target suddenly drops to reasonable numbers, and the P term in
    # our PID controller will drop our power to basically nothing.  Then we
    # waste precious time clawing back power -- potentially putting ourselves
    # right back in the same "can't produce enough" cycle.
    target = min(target, ratio + 0.2)

    case ControlAxis.step(old_axis, target, ratio) do
      {:changed, axis, new, _old} -> {axis, new}
      {:unchanged, axis, old} -> {axis, old}
    end
    |> then(fn {%ControlAxis{} = axis, value} ->
      turbine_count = Enum.count(old_turbines)
      total_power = axis_to_total_power(value, turbine_count)

      case update_power_levels(old_turbines, total_power, boost_mode, state.flow_control) do
        {:ok, new_turbines} ->
          {axis, new_turbines}

        {:error, :at_max, max_total_power, new_turbines} ->
          max_axis = total_power_to_axis(max_total_power, turbine_count)
          {axis |> ControlAxis.clamp(max_axis), new_turbines}
      end
    end)
    |> then(fn {%ControlAxis{} = axis, turbines} ->
      %State{
        state
        | axis: axis,
          turbines:
            turbines
            |> distribute_min_steam()
            |> Enum.map(&Turbine.tick/1)
      }
    end)
  end

  # Feedforward: when demand steps (new hour, new objective), jump the axis
  # to the estimated steady-state power for the new demand instead of
  # letting the PID discover it through accumulated error. The gain
  # (kW per power level) is measured from the current operating point, so
  # no plant model is needed; the PID trims from there.
  # Below this supply the measured gain is meaningless (startup, trip):
  @feedforward_min_supply_kw 1000

  defp maybe_feedforward(axis, _state, nil, _target, _supply), do: axis

  defp maybe_feedforward(axis, %State{} = state, {old_demand, new_demand}, target, supply_kw) do
    turbine_count = Enum.count(state.turbines)
    total_power = state.turbines |> Enum.sum_by(& &1.power_level)

    usable? =
      turbine_count > 0 and total_power > 0 and supply_kw >= @feedforward_min_supply_kw

    if usable? do
      kw_per_level = supply_kw / total_power

      ff_total =
        (target * new_demand / kw_per_level)
        |> round()
        |> max(@power_levels.first * turbine_count)
        |> min(@power_levels.last * turbine_count)

      Logger.notice([
        @log_prefix,
        "Feedforward: demand #{round(old_demand)} -> #{round(new_demand)} kW, ",
        "rebasing total power #{total_power} -> #{ff_total}."
      ])

      ControlAxis.clamp(axis, total_power_to_axis(ff_total, turbine_count))
    else
      axis
    end
  end

  defp get_target_ratio_and_deadzone(%State{target_override: nil, demand_tracker: dt}),
    do: DemandTracker.target_and_deadzone(dt)

  defp get_target_ratio_and_deadzone(%State{target_override: {{ratio, :ratio}, _}}),
    do: {ratio, @override_deadzone}

  defp get_target_ratio_and_deadzone(%State{
         target_override: {{target_mw, :mw}, _},
         demand_tracker: %DemandTracker{demand_kwh: demand_kw}
       }) do
    {target_mw * 1000 / demand_kw, @override_deadzone}
  end

  defp get_current_supply(turbines) do
    turbines
    |> Enum.map(&Turbine.get_generated_power/1)
    |> Enum.sum()
    |> Kernel.-(API.Power.get_used_kw())
  end

  def get_closed_breakers do
    @loops |> Enum.filter(&API.Generator.get_is_connected/1)
  end

  defp describe_override({r, :ratio}), do: "#{r * 100}%"
  defp describe_override({mw, :mw}), do: "#{mw} MW"

  defp describe_expiry(:never), do: "does not expire"
  defp describe_expiry(ts), do: "expires at #{ANTime.timestamp_to_string(ts)}"

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

  defp update_power_levels(old_turbines, target_total, boost_mode, flow_control) do
    power_levels = old_turbines |> Enum.map(&PowerLevel.new(&1, boost_mode))
    current_total = power_levels |> Enum.sum_by(& &1.power_level)

    flow_control = flow_control || 9999
    to_allocate = min(target_total, flow_control) - current_total

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
      target_total > flow_control ->
        Logger.warning(
          @log_prefix <> "Flow control: Limiting power from #{target_total} to #{flow_control}."
        )

        {:error, :at_max, new_total, new_turbines}

      new_total == target_total ->
        {:ok, new_turbines}

      new_total < target_total ->
        {:error, :at_max, new_total, new_turbines}
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
    if ANTime.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Target override has expired.")
      %State{state | target_override: nil}
    else
      state
    end
  end

  defp maybe_expire_boost_mode(%State{boost_mode: nil} = state), do: state
  defp maybe_expire_boost_mode(%State{boost_mode: :never} = state), do: state

  defp maybe_expire_boost_mode(%State{boost_mode: ts} = state) when is_integer(ts) do
    if ANTime.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Boost mode has expired.")
      %State{state | boost_mode: nil}
    else
      state
    end
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

  defp current_flow_limited_power(state) do
    total_power = state.turbines |> Enum.sum_by(& &1.power_level)

    if state.flow_control do
      total_power |> min(state.flow_control)
    else
      total_power
    end
  end
end
