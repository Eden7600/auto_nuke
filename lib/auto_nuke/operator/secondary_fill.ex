defmodule AutoNuke.Operator.SecondaryFill do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:loop, :steam_gen, :speed, :pump_capacity]
    defstruct(
      loop: nil,
      steam_gen: nil,
      speed: nil,
      pump_capacity: nil,
      adjustment: nil,
      boost_mode: nil
    )
  end

  alias AutoNuke.API
  alias AutoNuke.API.{SteamGen, Pumps, Vessels}
  alias AutoNuke.Time, as: ANTime

  # Target between 45% and 55% fill.
  @fill_target_min 0.45
  @fill_target_max 0.55
  # Outside this range, adjust pump speed by 1, until reaching 50%.
  @fill_target_pump_adjust 1
  # Keep fill between 30% and 70%.
  @fill_limit_min 0.30
  @fill_limit_max 0.70
  # Outside this range, we have a 10% scaling range.
  # This will scale pumps up to 100% at 20% fill or lower,
  # and down to 0% at 80% fill or higher.
  @fill_limit_span 0.10

  defp process_name(loop), do: __MODULE__ |> Module.concat("L#{loop}")

  def child_spec(opts) do
    loop = Keyword.fetch!(opts, :loop)

    %{
      id: process_name(loop),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    {loop, opts} = Keyword.pop!(opts, :loop)
    opts = Keyword.put_new(opts, :name, process_name(loop))
    GenServer.start_link(__MODULE__, loop, opts)
  end

  def set_boost_mode(loop_or_pid, expiry \\ :next_hour)

  def set_boost_mode(loop, expiry) when is_integer(loop),
    do: process_name(loop) |> set_boost_mode(expiry)

  def set_boost_mode(pid, expiry) when is_pid(pid) or is_atom(pid) do
    GenServer.call(pid, {:boost_mode, ANTime.parse_expiry(expiry)})
  end

  def clear_boost_mode(loop) when is_integer(loop),
    do: process_name(loop) |> clear_boost_mode()

  def clear_boost_mode(pid) when is_pid(pid) or is_atom(pid) do
    GenServer.call(pid, {:boost_mode, nil})
  end

  @impl true
  def init(loop) when loop in 1..3 do
    if is_installed?(loop) do
      do_init(loop)
    else
      Logger.info(log_prefix(loop) <> "Loop is not operational.")
      {:ok, nil}
    end
  end

  defp do_init(loop) do
    steam_gen = SteamGen.for_loop(loop)
    pump = steam_gen.pump
    capacity = Pumps.get_capacity(pump)
    speed = Pumps.get_ordered_speed(pump)

    state = %State{
      loop: loop,
      steam_gen: steam_gen,
      speed: speed,
      pump_capacity: capacity
    }

    PubSub.subscribe(self(), :ticker)

    Logger.info([
      log_prefix(loop),
      "Started with pump capacity #{capacity}",
      " and fill level of ",
      steam_gen.vessel
      |> Vessels.get_fill_percent()
      |> Float.round(2)
      |> Float.to_string(),
      "%."
    ])

    {:ok, state}
  end

  @impl true
  def handle_call({:boost_mode, expiry}, _from, %State{loop: loop} = state) do
    desc =
      case expiry do
        nil -> "disabled"
        :never -> "enabled, no expiry"
        ts -> "enabled until #{ANTime.timestamp_to_string(ts)}"
      end

    Logger.notice(log_prefix(loop) <> "Boost mode #{desc}.")
    {:reply, :ok, %State{state | boost_mode: expiry}}
  end

  def handle_call({:boost_mode, _expiry}, _from, nil) do
    {:reply, {:error, :not_running}, nil}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{loop: loop, speed: old_speed} = state) do
    state = maybe_expire_boost_mode(state)

    steam_gen = state.steam_gen
    fill_level = Vessels.get_fill_ratio(steam_gen.vessel)
    adjust = determine_adjustment(state.adjustment, fill_level)

    new_speed =
      SteamGen.get_outlet(steam_gen)
      |> maybe_boost(state.boost_mode)
      |> calculate_speed(state.pump_capacity, fill_level, adjust)

    if new_speed != old_speed && sanity_check(new_speed, loop) do
      Logger.info(log_prefix(loop) <> "Changing speed from #{old_speed} to #{new_speed}.")
      Pumps.set_speed(steam_gen.pump, new_speed)
    end

    {:noreply, %State{state | speed: new_speed, adjustment: adjust}}
  end

  defp maybe_boost(steam_out, nil), do: steam_out
  defp maybe_boost(_, _), do: 999_999

  defp determine_adjustment(nil, f) when f < @fill_target_min, do: :fill
  defp determine_adjustment(nil, f) when f > @fill_target_max, do: :empty
  defp determine_adjustment(:fill, f) when f >= 0.5, do: nil
  defp determine_adjustment(:empty, f) when f <= 0.5, do: nil
  defp determine_adjustment(current, _), do: current

  defp calculate_speed(steam_outlet, pump_capacity, fill_level, adjust) do
    ideal = steam_outlet / pump_capacity * 100

    cond do
      fill_level < @fill_limit_min ->
        error = @fill_limit_min - fill_level
        percent = (error / @fill_limit_span) |> min(1.0)
        adjust = (100 - ideal) * percent
        ideal + max(adjust, @fill_target_pump_adjust)

      fill_level > @fill_limit_max ->
        error = fill_level - @fill_limit_max
        percent = (error / @fill_limit_span) |> min(1.0)
        adjust = ideal * percent
        ideal - max(adjust, @fill_target_pump_adjust)

      adjust == :fill ->
        ideal + @fill_target_pump_adjust

      adjust == :empty ->
        ideal - @fill_target_pump_adjust

      true ->
        ideal
    end
    |> round()
    |> max(0)
    |> min(100)
  end

  defp maybe_expire_boost_mode(%State{boost_mode: nil} = state), do: state
  defp maybe_expire_boost_mode(%State{boost_mode: :never} = state), do: state

  defp maybe_expire_boost_mode(%State{loop: loop, boost_mode: ts} = state) when is_integer(ts) do
    if ANTime.get_current_time() >= ts do
      Logger.notice(log_prefix(loop) <> "Boost mode has expired.")
      %State{state | boost_mode: nil}
    else
      state
    end
  end

  defp sanity_check(0, loop) do
    power = API.Generator.get_power_kw(loop)

    if power > 0.1 do
      Logger.warning([
        log_prefix(loop),
        "Sanity check failed: Power is #{power} kW, refusing to zero pump speed."
      ])

      false
    else
      true
    end
  end

  defp sanity_check(_speed, _loop), do: true

  defp is_installed?(loop) do
    API.get_json("INSTALLED_LOOPS_JSON")
    |> Map.fetch!("Loop_#{loop - 1}")
    |> Map.values()
    |> Enum.all?()
  end

  def axis_to_speed(output), do: round(50 + output * 50)
  def speed_to_axis(speed), do: (speed - 50) / 50

  @log_module inspect(__MODULE__) |> String.replace("AutoNuke.Operator.", "")
  defp log_prefix(loop), do: "[#{@log_module}.L#{loop}] "
end
