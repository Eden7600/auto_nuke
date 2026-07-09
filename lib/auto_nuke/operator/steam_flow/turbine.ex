defmodule AutoNuke.Operator.SteamFlow.Turbine do
  @enforce_keys [
    # Loop number
    :loop,
    # ControlAxis controlling turbine bypass needed to reach min_steam
    :steam_axis,
    # ControlAxis controlling turbine bypass needed to stay at a safe pressure
    :pressure_axis,
    # Secondary pump capacity, used to determine our max power level
    :secondary_capacity,
    # Steam generator, used to access outlet and valves
    :steam_gen,
    # Current bypass setting
    :bypass,
    # Target power level, assigned by parent (based on power requirements)
    :power_level,
    # Minimum steam requirement, assigned by parent
    :min_steam,
    # Latest readings
    :steam,
    :pressure,
    # Historical pressure readings, used to project future trend
    :pressure_history
  ]
  defstruct(@enforce_keys)

  # Allowed power levels:
  @power_levels 2..100
  def allowed_power_levels, do: @power_levels
  # Keep pressure under 65 bar when at low power.
  @max_pressure 65
  # Every 2 bar above 65 bar = +1 max steam we can pull immediately.
  @excess_per_bar 0.5
  # If pressure is below 55 bar, we're starved for steam and shouldn't try to
  # push power level any higher.
  @min_pressure 55
  # If pressure is below 50 bar, start backing off power.
  @critical_pressure 50
  # To avoid excessive flapping, if we're within 3 kg/min 
  # of min steam flow, disallow bypass decreases.
  @steam_lock_zone 3
  # Allow power levels beyond pump capacity at a rate
  # of one level per 20 hL of water volume beyond 100 hL.
  defp boost_limit(water_hl), do: ((water_hl - 10000) / 2000) |> floor()

  # Keep the last 10 pressure readings:
  @pressure_history_size 10
  # Look ahead 5 more readings during power allocation:
  @pressure_lookahead 5

  # I'm told that as long as MSCV and bypass add up to 11 or higher,
  # we shouldn't have any risk of pressure excursions on the steam gens.
  # Let's put that to the test.
  @pressure_bypass_combined 11

  require Logger
  alias __MODULE__
  alias AutoNuke.API.{SteamGen, Valves, Pumps, Generator, Vessels}
  alias AutoNuke.ControlAxis
  alias AutoNuke.Smoother

  def new(loop) when loop in 1..3 do
    steam_gen = SteamGen.for_loop(loop)
    mscv = Valves.get_open_percent(steam_gen.mscv) |> round()
    bypass = Valves.get_open_percent(steam_gen.bypass) |> round()

    steam_axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.001,
        deadzone: 1.0,
        to_value_fn: &axis_to_bypass/1,
        offset: bypass |> bypass_to_axis(),
        initial_value: bypass
      )

    pressure_axis =
      ControlAxis.new(
        kp: -0.01,
        ki: -0.001,
        deadzone: 0.5,
        to_value_fn: &axis_to_bypass/1,
        offset: bypass |> bypass_to_axis(),
        initial_value: bypass
      )

    pressure = SteamGen.get_pressure(steam_gen)

    %Turbine{
      loop: loop,
      steam_axis: steam_axis,
      pressure_axis: pressure_axis,
      secondary_capacity: Pumps.secondary(loop) |> Pumps.get_capacity(),
      steam_gen: steam_gen,
      bypass: bypass,
      power_level: mscv |> mscv_to_power_level(),
      min_steam: 0,
      steam: SteamGen.get_outlet(steam_gen),
      pressure: pressure,
      pressure_history: Smoother.new(@pressure_history_size) |> Smoother.add(pressure)
    }
  end

  def set_min_steam(%Turbine{} = turbine, new) do
    %Turbine{turbine | min_steam: new}
  end

  def set_power_level(%Turbine{loop: loop, power_level: old, steam_gen: steam_gen} = turbine, new)
      when new in @power_levels do
    Logger.info(log_prefix(loop) <> "Changing power level from #{old} to #{new}.")
    Valves.set_open_percent(steam_gen.mscv, new)
    %Turbine{turbine | power_level: new}
  end

  def max_power_level(
        %Turbine{
          steam_gen: steam_gen,
          secondary_capacity: capacity
        },
        boost_mode
      )
      when is_boolean(boost_mode) do
    steam_level =
      steam_gen
      |> SteamGen.get_outlet()
      |> Kernel./(10)
      |> round()

    pressure = SteamGen.get_pressure(steam_gen)

    cond do
      pressure < @critical_pressure ->
        steam_level - 1

      pressure < @min_pressure ->
        steam_level

      pressure <= @max_pressure ->
        steam_level + 1

      pressure > @max_pressure ->
        excess =
          ((pressure - @max_pressure) * @excess_per_bar)
          |> round()
          |> Kernel.+(2)

        steam_level + excess
    end
    |> limit_power_level(div(capacity, 10), boost_mode, steam_gen.vessel)
  end

  defp limit_power_level(power_level, pump_capacity, _, _)
       when power_level <= pump_capacity,
       do: power_level

  defp limit_power_level(_, pump_capacity, false, _), do: pump_capacity

  defp limit_power_level(power_level, pump_capacity, true, %Vessels.Vessel{} = vessel) do
    boost = Vessels.get_fill_volume(vessel) |> boost_limit()
    power_level |> min(pump_capacity + boost)
  end

  def get_generated_power(%Turbine{loop: loop}), do: Generator.get_power_kw(loop)

  def steam_via_bypass(%Turbine{power_level: power_level, steam: steam}),
    do: steam - power_level * 10

  # Guess where pressure will be in `from_now` ticks.
  def guess_future_pressure(%Turbine{pressure_history: history}) do
    Smoother.extrapolate(history, @pressure_lookahead)
  end

  def tick(%Turbine{loop: loop, steam_gen: steam_gen} = turbine) do
    steam = SteamGen.get_outlet(steam_gen)
    pressure = SteamGen.get_pressure(steam_gen)

    {steam_bypass, steam_axis} =
      step_axis(
        turbine.steam_axis,
        steam,
        turbine.min_steam
      )
      |> maybe_unstep_steam(steam - turbine.min_steam, turbine)

    {pressure_bypass, pressure_axis} =
      step_axis(
        turbine.pressure_axis,
        pressure,
        @max_pressure
      )
      |> then(fn {bypass, axis} ->
        max = (@pressure_bypass_combined - turbine.power_level) |> max(0)

        if bypass > max do
          {max, ControlAxis.clamp(axis, bypass_to_axis(max), max)}
        else
          {bypass, axis}
        end
      end)

    old = turbine.bypass

    {new, reason} =
      cond do
        steam_bypass > pressure_bypass -> {steam_bypass, "min steam"}
        pressure_bypass > steam_bypass -> {pressure_bypass, "max pressure"}
        true -> {pressure_bypass, "both concerns"}
      end

    if old != new do
      Logger.info(log_prefix(loop) <> "Changing bypass from #{old} to #{new} due to #{reason}.")
      Valves.set_open_percent(steam_gen.bypass, new)
    end

    %Turbine{
      turbine
      | steam_axis: steam_axis,
        pressure_axis: pressure_axis,
        bypass: new,
        steam: steam,
        pressure: pressure,
        pressure_history: turbine.pressure_history |> Smoother.add(pressure)
    }
  end

  defp step_axis(axis, current, target) do
    case ControlAxis.step(axis, target, current) do
      {:changed, axis, new, _old} -> {new, axis}
      {:unchanged, axis, old} -> {old, axis}
    end
  end

  defp maybe_unstep_steam({new_bypass, _}, margin, %Turbine{
         bypass: old_bypass,
         steam_axis: old_axis
       })
       when new_bypass < old_bypass and margin < @steam_lock_zone, do: {old_bypass, old_axis}

  defp maybe_unstep_steam({_, _} = rval, _, _), do: rval

  @log_module inspect(__MODULE__) |> String.replace("AutoNuke.Operator.", "")
  defp log_prefix(loop), do: "[#{@log_module}.L#{loop}] "

  defp axis_to_bypass(output), do: round(output * 50) + 50
  defp bypass_to_axis(bypass), do: (bypass - 50) / 50

  defp mscv_to_power_level(n) when n in @power_levels, do: n
  defp mscv_to_power_level(n), do: n |> max(@power_levels.first) |> min(@power_levels.last)
end
