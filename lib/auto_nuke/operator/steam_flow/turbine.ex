defmodule AutoNuke.Operator.SteamFlow.Turbine do
  @enforce_keys [
    # Loop number
    :loop,
    # ControlAxis controlling turbine bypass needed to reach min_steam
    :steam_axis,
    # ControlAxis controlling turbine bypass needed to stay at a safe pressure
    :pressure_axis,
    # Primary pump capacity, used to determine our PL ratio compared to other turbines
    :primary_capacity,
    # Secondary pump capacity, used to determine our max power level
    :secondary_capacity,
    # Current bypass setting
    :bypass,
    # Target power level, assigned by parent (based on power requirements)
    :power_level,
    # Minimum steam requirement, assigned by parent (based on number of turbines)
    :min_steam
  ]
  defstruct(@enforce_keys)

  # Allowed power levels:
  @power_levels 2..30
  def allowed_power_levels, do: @power_levels
  # Keep pressure under 65 bar.
  @max_pressure 65

  require Logger
  alias __MODULE__
  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  def new(loop, min_steam) when loop in 1..3 and min_steam > 0 do
    bypass = get_bypass(loop)

    steam_axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.001,
        deadzone: 0.5,
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

    %Turbine{
      loop: loop,
      steam_axis: steam_axis,
      pressure_axis: pressure_axis,
      primary_capacity: get_capacity("CORE", loop),
      secondary_capacity: get_capacity("SEC", loop),
      bypass: get_bypass(loop),
      power_level: get_mscv(loop) |> round() |> mscv_to_power_level(),
      min_steam: min_steam
    }
  end

  def set_min_steam(%Turbine{loop: loop, min_steam: old} = turbine, new) do
    Logger.info(log_prefix(loop) <> "Changing minimum steam from #{old} to #{new}.")
    %Turbine{turbine | min_steam: new}
  end

  def set_power_level(%Turbine{loop: loop, power_level: old} = turbine, new)
      when new in @power_levels do
    Logger.info(log_prefix(loop) <> "Changing power level from #{old} to #{new}.")
    set_mscv(loop, mscv_setting(new))
    %Turbine{turbine | power_level: new}
  end

  def max_power_level(%Turbine{loop: loop, secondary_capacity: capacity}) do
    get_steam_outlet(loop)
    |> Kernel./(10)
    |> round()
    |> Kernel.+(1)
    |> min(div(capacity, 10))
  end

  def tick(%Turbine{loop: loop} = turbine) do
    {steam_bypass, steam_axis} =
      step_axis(
        turbine.steam_axis,
        get_steam_outlet(loop),
        turbine.min_steam
      )

    {pressure_bypass, pressure_axis} =
      step_axis(
        turbine.pressure_axis,
        get_pressure(loop),
        @max_pressure
      )

    old = turbine.bypass

    {new, reason} =
      cond do
        steam_bypass > pressure_bypass -> {steam_bypass, "min steam"}
        pressure_bypass > steam_bypass -> {pressure_bypass, "max pressure"}
        true -> {pressure_bypass, "both concerns"}
      end

    if old != new do
      Logger.info(log_prefix(loop) <> "Changing bypass from #{old} to #{new} due to #{reason}.")
      set_bypass(loop, new)
    end

    %Turbine{turbine | steam_axis: steam_axis, pressure_axis: pressure_axis, bypass: new}
  end

  defp step_axis(axis, current, target) do
    case ControlAxis.step(axis, target, current) do
      {:changed, axis, new, _old} -> {new, axis}
      {:unchanged, axis, old} -> {old, axis}
    end
  end

  defp mscv_setting(n) when n in @power_levels, do: n

  defp get_steam_outlet(loop), do: API.get_float("STEAM_GEN_#{loop - 1}_OUTLET")
  defp get_pressure(loop), do: API.get_float("COOLANT_SEC_#{loop - 1}_PRESSURE")

  defp get_bypass(loop), do: API.get_float("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL")
  defp set_bypass(loop, value), do: API.put("STEAM_TURBINE_#{loop - 1}_BYPASS_ORDERED", value)

  defp get_mscv(loop), do: API.get_float("MSCV_#{loop - 1}_OPENING_ACTUAL")
  defp set_mscv(loop, value), do: API.put("MSCV_#{loop - 1}_OPENING_ORDERED", value)

  @module_name inspect(__MODULE__)
  defp log_prefix(loop) when loop in 1..3, do: "[#{@module_name}.L#{loop}] "

  defp axis_to_bypass(output), do: round(output * 50) + 50
  defp bypass_to_axis(bypass), do: (bypass - 50) / 50

  defp mscv_to_power_level(0), do: 2
  defp mscv_to_power_level(1), do: 2
  defp mscv_to_power_level(n) when n in @power_levels, do: n

  defp get_capacity(type, loop) do
    API.get_integer("COOLANT_#{type}_CIRCULATION_PUMP_#{loop - 1}_CAPACITY")
  end
end
