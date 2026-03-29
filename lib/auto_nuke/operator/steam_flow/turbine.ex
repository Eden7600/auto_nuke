defmodule AutoNuke.Operator.SteamFlow.Turbine do
  @enforce_keys [:loop, :axis, :bypass, :power_level, :min_steam]
  defstruct(
    # Loop number
    loop: nil,
    # ControlAxis controlling turbine bypass
    axis: nil,
    # Current bypass setting
    bypass: nil,
    # Target power level, assigned by parent (based on power requirements)
    power_level: nil,
    # Minimum steam requirement, assigned by parent (based on number of turbines)
    min_steam: nil,
    # Functions for current and target, based on power level
    current_fn: nil,
    target_fn: nil
  )

  # When at power level 1, target 2.5% torque:
  @torque_target 2.5
  # When at power levels 2 and above, we target `turbine.min_steam` instead.

  # If pressure exceeds about 70 bar, we're having a pressure excursion event.
  @max_pressure 70
  # Above that pressure, override bypass and open by 2% every bar.
  defp pressure_min_bypass(loop), do: ceil(get_pressure(loop) - @max_pressure) * 2

  require Logger
  alias __MODULE__
  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  def new(loop, min_steam) when loop in 1..3 and min_steam > 0 do
    %Turbine{
      loop: loop,
      axis: nil,
      bypass: get_bypass(loop),
      power_level: guess_power_level(loop),
      min_steam: min_steam
    }
    |> change_control_mode()
  end

  def set_min_steam(%Turbine{loop: loop, min_steam: old} = turbine, new) do
    Logger.info(log_prefix(loop) <> "Changing minimum steam from #{old} to #{new}.")
    %Turbine{turbine | min_steam: new}
  end

  def set_power_level(%Turbine{loop: loop, power_level: old} = turbine, new) do
    Logger.info(log_prefix(loop) <> "Changing power level from #{old} to #{new}.")
    set_mscv(loop, mscv_setting(new))

    %Turbine{turbine | power_level: new}
    |> change_control_mode()
  end

  def max_power_level(%Turbine{loop: loop}) do
    get_steam_outlet(loop)
    |> Kernel./(10)
    |> round()
    |> Kernel.+(1)
  end

  def tick(%Turbine{loop: loop} = turbine) do
    current = turbine.current_fn.(turbine)
    target = turbine.target_fn.(turbine)

    case ControlAxis.step(turbine.axis, target, current) do
      {:changed, axis, new, _old} -> {axis, new}
      {:unchanged, axis, old} -> {axis, old}
    end
    |> then(fn {axis, new} ->
      old = turbine.bypass
      new = new |> max(pressure_min_bypass(loop))

      if old != new do
        Logger.info(log_prefix(loop) <> "Changing bypass from #{old} to #{new}.")
        set_bypass(loop, new)
      end

      %Turbine{turbine | axis: axis, bypass: new}
    end)
  end

  # Power level 1: Target 2.5% torque.
  defp change_control_mode(%Turbine{loop: loop, power_level: 1} = turbine) do
    bypass = get_bypass(loop)

    axis =
      ControlAxis.new(
        kp: -0.2,
        ki: -0.05,
        deadzone: 0.1,
        to_value_fn: &axis_to_bypass/1,
        offset: bypass |> bypass_to_axis(),
        initial_value: bypass
      )

    %Turbine{
      turbine
      | axis: axis,
        current_fn: fn %Turbine{loop: loop} -> get_turbine_torque(loop) end,
        target_fn: fn _ -> @torque_target end
    }
  end

  # Power levels 2 and up: Target `min_steam` steam output.
  defp change_control_mode(%Turbine{loop: loop} = turbine) do
    bypass = get_bypass(loop)

    axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.001,
        deadzone: 0.5,
        to_value_fn: &axis_to_bypass/1,
        offset: bypass |> bypass_to_axis(),
        initial_value: bypass
      )

    %Turbine{
      turbine
      | axis: axis,
        current_fn: fn %Turbine{loop: loop} -> get_steam_outlet(loop) end,
        target_fn: fn %Turbine{min_steam: min_steam} -> min_steam end
    }
  end

  defp mscv_setting(power_level)
  # Power level 1 is still MSCV 2, but with as much bypass as possible.
  defp mscv_setting(1), do: 2
  # Power level 2 and up use the given MSCV with as little bypass as possible.
  defp mscv_setting(n) when n in 2..100, do: n

  defp get_steam_outlet(loop), do: API.get_float("STEAM_GEN_#{loop - 1}_OUTLET")
  defp get_pressure(loop), do: API.get_float("COOLANT_SEC_#{loop - 1}_PRESSURE")
  defp get_turbine_torque(loop), do: API.get_float("STEAM_TURBINE_#{loop - 1}_TORQUE")

  defp get_bypass(loop), do: API.get_float("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL")
  defp set_bypass(loop, value), do: API.put("STEAM_TURBINE_#{loop - 1}_BYPASS_ORDERED", value)

  defp get_mscv(loop), do: API.get_float("MSCV_#{loop - 1}_OPENING_ACTUAL")
  defp set_mscv(loop, value), do: API.put("MSCV_#{loop - 1}_OPENING_ORDERED", value)

  @module_name inspect(__MODULE__)
  defp log_prefix(loop) when loop in 1..3, do: "[#{@module_name}.L#{loop}] "

  defp axis_to_bypass(output), do: round(output * 50) + 50
  defp bypass_to_axis(bypass), do: (bypass - 50) / 50

  defp guess_power_level(loop) do
    case get_mscv(loop) |> round() do
      0 -> 0
      1 -> 0
      2 -> guess_power_level_two(loop)
      n when n in 3..100 -> n
    end
  end

  # This isn't an exact science, but since there are basically no constraints
  # on power level 1 reaching the target torque value, we can generally assume
  # that if we inherit a torque close to / below target, we're at power level 1.
  defp guess_power_level_two(loop) do
    offset = get_turbine_torque(loop) - @torque_target
    if offset < 0.2, do: 1, else: 2
  end
end
