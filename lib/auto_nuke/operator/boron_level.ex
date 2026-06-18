defmodule AutoNuke.Operator.BoronLevel do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:dosing_rate, :filter_axis]
    defstruct(
      dosing_rate: nil,
      filter_axis: nil,
      filter_ready: false,
      next_ready_check: 0,
      next_pump_check: nil
    )
  end

  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Ion pump begins filtering when rods are below 20%, with a 0.5% deadzone.
  @filter_target 20
  @filter_deadzone 0.5
  # Maximum filter speed is 100%.
  @filter_max_rate 100

  # I'm told boron beyond 3500 has no effect.
  # Practically speaking, it's hard to maintain at 3500 anyway.
  @dosing_max_ppm 3500

  # Peform ready check once every 10 in-game seconds:
  tps = AutoNuke.Ticker.ticks_per_second()
  @ready_check_interval 10 * tps
  # If filter pump does not turn on within 3 seconds, begin issuing warnings:
  @pump_check_interval 3 * tps

  @dosing_pump API.Pumps.boron_dosing()
  @filter_pump API.Pumps.boron_filter()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    using_chemicals?()
    |> maybe_init()
  end

  defp maybe_init(false) do
    Logger.info(@log_prefix <> "Chemicals not enabled (or no pumps installed).  Going to sleep.")
    {:ok, nil, :hibernate}
  end

  defp maybe_init(true) do
    boron = get_boron_ppm()
    filter_speed = @filter_pump |> API.Pumps.get_ordered_speed()
    dose_rate = @dosing_pump |> API.Pumps.get_ordered_speed()

    filter_axis =
      ControlAxis.new(
        kp: 0.001,
        ki: 0.0001,
        kd: 0.0005,
        deadzone: @filter_deadzone,
        to_value_fn: &axis_to_filter/1,
        offset: filter_speed |> filter_to_axis(),
        initial_value: filter_speed
      )

    state = %State{dosing_rate: dose_rate, filter_axis: filter_axis}

    PubSub.subscribe(self(), :ticker)

    Logger.info([
      @log_prefix,
      "Started with boron at #{boron} ppm,",
      " dosing at #{dose_rate} g/min,",
      " and filtration at #{filter_speed}%."
    ])

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, t}, %State{} = state) do
    rods = API.get_float("RODS_POS_ACTUAL")

    {:noreply,
     state
     |> tick_dosing(rods)
     |> tick_filter(rods, t)}
  end

  defp tick_dosing(%State{dosing_rate: old} = state, rods) do
    new = calculate_dosing_rate(rods)

    if new != old do
      Logger.info(@log_prefix <> "Changing dosing rate from #{old} to #{new} g/min.")
      @dosing_pump |> API.Pumps.set_speed(new)
      %State{state | dosing_rate: new}
    else
      state
    end
  end

  defp tick_filter(%State{filter_axis: axis} = state, rods, t) do
    state = ready_check(state, t)

    case ControlAxis.step(axis, @filter_target, rods) do
      {:changed, axis, new, old} ->
        if state.filter_ready || new == 0 do
          Logger.info(@log_prefix <> "Changing filter speed from #{old}% to #{new}%.")
          @filter_pump |> API.Pumps.set_speed(new)
          {axis, new}
        else
          Logger.error(@log_prefix <> "Filtration not ready!  Cannot change speed to #{new}%.")
          @filter_pump |> API.Pumps.set_speed(0)
          {ControlAxis.clamp_min(axis, 0.0), 0}
        end

      {:unchanged, axis, old} ->
        {axis, old}
    end
    |> then(fn {axis, value} ->
      %State{state | filter_axis: axis}
      |> pump_check(t, value)
    end)
  end

  defp using_chemicals? do
    [@dosing_pump, @filter_pump] |> Enum.any?(&API.Pumps.installed?/1)
  end

  defp get_boron_ppm, do: API.get_float("CHEM_BORON_PPM")

  # Control rods are above target, so output is negative, nothing to do:
  defp axis_to_filter(output) when output <= 0.0, do: 0
  # Control rods are below target, so output is positive, time to start filtering:
  defp axis_to_filter(output) when output > 0.0, do: (output * filter_max()) |> round()

  defp filter_to_axis(filter), do: filter / @filter_max_rate

  defp calculate_dosing_rate(rods) do
    # Add 1 g/min for every 2% above 50% rods, to a max of 25 g/min.
    ((rods - 50) / 2)
    |> floor()
    # Limit our rate to whatever rate will get us to 3500 ppm.
    |> min(@dosing_max_ppm - get_boron_ppm())
    |> max(0)
  end

  # Below 100 ppm, start throttling back.
  #
  # I don't actually know if we can completely eliminate all boron,
  # so this scales filtering down as we approach zero.
  #
  # Realistically, by the time we get this low, 
  # we're probably in a xenon pit and screwed anyway.
  defp filter_max do
    @filter_max_rate
    |> min(get_boron_ppm())
  end

  defp ready_check(%State{next_ready_check: t2} = state, t1) when t2 < t1, do: state

  @filter_valves [
    API.Valves.ion_inlet(),
    API.Valves.ion_outlet()
  ]
  defp ready_check(%State{} = state, t) do
    not_ready = fn vs, is_are ->
      Logger.warning("Ion filtration not ready: #{vs} valve #{is_are} closed.")
      false
    end

    case @filter_valves |> Enum.reject(&API.Valves.get_opened?/1) do
      [] ->
        true

      [v] ->
        not_ready.(v.short_name, "is")

      valves ->
        valves
        |> Enum.map(& &1.short_name)
        |> Enum.join(" and ")
        |> then(&not_ready.(&1, "are"))
    end
    |> then(fn r when is_boolean(r) ->
      %State{state | filter_ready: r, next_ready_check: t + @ready_check_interval}
    end)
  end

  # No filtration requested, disable checks if enabled:
  defp pump_check(%State{next_pump_check: t} = state, _, 0) do
    case t do
      nil -> state
      _ -> %State{state | next_pump_check: nil}
    end
  end

  # We just started asking for filtration, schedule the first check:
  defp pump_check(%State{next_pump_check: nil} = state, t, f) when f > 0 do
    %State{state | next_pump_check: t + @pump_check_interval}
  end

  # Not time for another check yet:
  defp pump_check(%State{next_pump_check: t2} = state, t1, _)
       when is_integer(t2) and t2 < t1, do: state

  # Filtration is requested, and it's time for a check:
  defp pump_check(%State{} = state, t, f) when f > 0 do
    if @filter_pump |> API.Pumps.get_actual_speed() < 1.0 do
      Logger.error("Filtration pump not activating.  Check ion exchange switch.")
    end

    %State{state | next_pump_check: t + @pump_check_interval}
  end
end
