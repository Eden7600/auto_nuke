defmodule AutoNuke.Operator.SteamFlow.Turbine do
  @enforce_keys [:loop, :axis, :bypass, :power_level, :min_steam]
  defstruct(
    # Loop number
    loop: nil,
    # ControlAxis controlling turbine bypass
    axis: nil,
    # Currently ordered turbine bypass setting
    bypass: nil,
    # Target power level, assigned by parent (based on power requirements)
    power_level: nil,
    # Minimum steam requirement, assigned by parent (based on number of turbines)
    min_steam: nil
  )

  require Logger
  alias __MODULE__
  alias AutoNuke.API
  alias AutoNuke.ControlAxis

  def new(loop, min_steam) when loop in 1..3 and min_steam > 0 do
    bypass = get_bypass(loop) |> round()

    axis =
      ControlAxis.new(
        kp: 0.5,
        ki: 0.1,
        deadzone: 0.01,
        to_value_fn: &axis_to_bypass/1,
        offset: bypass |> bypass_to_axis(),
        initial_value: bypass
      )

    %Turbine{
      loop: loop,
      axis: axis,
      bypass: bypass,
      power_level: guess_power_level(loop),
      min_steam: min_steam
    }
  end

  def set_min_steam(%Turbine{loop: loop, min_steam: old} = turbine, new) do
    Logger.info(log_prefix(loop) <> "Changing minimum steam from #{old} to #{new}.")
    %Turbine{turbine | min_steam: new}
  end

  def set_power_level(%Turbine{loop: loop, power_level: old} = turbine, new) do
    Logger.info(log_prefix(loop) <> "Changing power level from #{old} to #{new}.")
    set_mscv(loop, mscv_setting(new))
    %Turbine{turbine | power_level: new}
  end

  def tick(%Turbine{loop: loop, axis: axis} = turbine) do
    ratio = get_current_value(turbine)

    case ControlAxis.step(axis, 0.0, ratio) do
      {:changed, axis, new, old} ->
        Logger.info(log_prefix(loop) <> "Changing bypass from #{old} to #{new}.")
        set_bypass(loop, new)
        %Turbine{turbine | axis: axis, bypass: new}

      {:unchanged, axis, _old_value} ->
        %Turbine{turbine | axis: axis}
    end
  end

  defp get_current_value(%Turbine{power_level: level} = turbine) do
    bypass_concerns(level)
    |> Enum.reduce(0.0, &apply_concern(turbine, &1, &2))
  end

  defp mscv_setting(power_level)
  # Power level 1 is still MSCV 2, but with as much bypass as possible.
  defp mscv_setting(1), do: 2
  # Power level 2 and up use the given MSCV with as little bypass as possible.
  defp mscv_setting(n) when n in 2..100, do: n

  # Lists the concerns for each power level, from least to most important.
  # Each concern will have the opportunity to adjust the output of the prior one.
  defp bypass_concerns(power_level)
  # At power level 1, we want as much bypass as possible.
  # Targeting torque directly should also address both the pressure and steam concerns:
  # Opening bypass wide should keep steam high and pressure low.
  # (Excessive pressure will raise torque, so we'll compensate automatically.)
  defp bypass_concerns(1), do: [:target_torque]
  # At power levels 2, 3, and 4, we need to
  #   1: avoid excessive pressure
  #   2: ensure enough steam
  #   3: otherwise, as little bypass as we can get away with
  # Thankfully, both 1 and 2 are solved with more bypass, so they work together.
  # Order is also irrelevant, since it'll just prioritise the more-violated concern.
  defp bypass_concerns(n) when n in 2..4, do: [:zero_bypass, :min_steam, :max_pressure]
  # At power level 5 and up, we shouldn't ever need bypass.
  # We could technically just use the same steps as levels 2 through 4,
  # but dropping them will avoid a bunch of useless API calls.
  # (This may change if I find a scenario where high heat + MSCV 5 = runaway pressure.)
  defp bypass_concerns(n) when n in 5..100, do: [:zero_bypass]

  # If our prior target calls for less bypass,
  # start applying the brakes when steam output is 10% above `min_steam`:
  @min_steam_margin 0.1
  # How aggressively to pursue our `min_steam` agenda:
  @min_steam_gain 1

  defp apply_concern(%Turbine{loop: loop, min_steam: min_steam}, :min_steam, old_value) do
    steam = get_steam_outlet(loop)
    margin = @min_steam_margin
    gain = @min_steam_gain

    # >0 = safe, 0 = at limit, <0 = violation
    normalized_error = (steam - min_steam) / min_steam
    # 0 = very safe, 0.x = approaching limit, 1 = violation
    activation_factor = clamp((margin - normalized_error) / margin, 0.0, 1.0)
    # 0 = safe, <0 = violation
    required_direction = clamp(normalized_error * gain, -1.0, 0.0)

    new_value = (1 - activation_factor) * old_value + activation_factor * required_direction
    min(old_value, new_value)
  end

  # When limiting pressure, target 60 bar:
  @max_pressure 60
  # If our prior target calls for less bypass,
  # start applying the brakes when pressure is 10% below `@max_pressure`:
  @max_pressure_margin 0.1
  # How aggressively to pursue our `@max_pressure` agenda:
  @max_pressure_gain 1

  defp apply_concern(%Turbine{loop: loop}, :max_pressure, old_value) do
    pressure = get_pressure(loop)
    margin = @max_pressure_margin
    gain = @max_pressure_gain

    # >0 = safe, 0 = at limit, <0 = violation
    normalized_error = (@max_pressure - pressure) / @max_pressure
    # 0 = very safe, 0.x = approaching limit, 1 = violation
    activation_factor = clamp((margin - normalized_error) / margin, 0.0, 1.0)
    # 0 = safe, <0 = violation
    required_direction = clamp(normalized_error * gain, -1.0, 0.0)

    new_value = (1 - activation_factor) * old_value + activation_factor * required_direction
    min(old_value, new_value)
  end

  # What torque value to target.
  # If torque is exactly this, then value will be zero (perfect bypass).
  @torque_target 2.5
  # What torque value to never go below.
  # If torque reaches or drops below this, then value will be +1 (too much bypass!)
  @torque_critical 2.0
  # Where to start slowing down our torque decrease.
  # Above this, value will be -1 (not enough bypass).
  # Below this, value will approach zero (perfect bypass).
  @torque_high 3.5

  defp apply_concern(%Turbine{loop: loop}, :target_torque, _old_value) do
    torque = get_turbine_torque(loop)

    cond do
      torque < @torque_target ->
        (torque - @torque_target) / (@torque_target - @torque_critical)

      torque > @torque_target ->
        (torque - @torque_target) / (@torque_high - @torque_target)

      torque == @torque_target ->
        0
    end
    |> clamp(-1.0, +1.0)
  end

  # This concern is simple: Always reduce bypass.
  defp apply_concern(%Turbine{}, :zero_bypass, _old_value), do: 1

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

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
