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
    # Steam generator, used to access outlet and valves
    :steam_gen,
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
  alias AutoNuke.API.{SteamGen, Valves, Pumps, Generator}
  alias AutoNuke.ControlAxis

  def new(loop, min_steam) when loop in 1..3 and min_steam > 0 do
    steam_gen = SteamGen.for_loop(loop)
    mscv = Valves.get_open_percent(steam_gen.mscv) |> round()
    bypass = Valves.get_open_percent(steam_gen.bypass) |> round()

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
      primary_capacity: Pumps.primary(loop) |> Pumps.get_capacity(),
      secondary_capacity: Pumps.secondary(loop) |> Pumps.get_capacity(),
      steam_gen: steam_gen,
      bypass: bypass,
      power_level: mscv |> mscv_to_power_level(),
      min_steam: min_steam
    }
  end

  def set_min_steam(%Turbine{loop: loop, min_steam: old} = turbine, new) do
    Logger.info(log_prefix(loop) <> "Changing minimum steam from #{old} to #{new}.")
    %Turbine{turbine | min_steam: new}
  end

  def set_power_level(%Turbine{loop: loop, power_level: old, steam_gen: steam_gen} = turbine, new)
      when new in @power_levels do
    Logger.info(log_prefix(loop) <> "Changing power level from #{old} to #{new}.")
    Valves.set_open_percent(steam_gen.mscv, new)
    %Turbine{turbine | power_level: new}
  end

  def max_power_level(%Turbine{steam_gen: steam_gen, secondary_capacity: capacity}) do
    steam_gen
    |> SteamGen.get_outlet()
    |> Kernel./(10)
    |> round()
    |> Kernel.+(1)
    |> min(div(capacity, 10))
  end

  def get_generated_power(%Turbine{loop: loop}), do: Generator.get_power_kw(loop)

  def tick(%Turbine{loop: loop, steam_gen: steam_gen} = turbine) do
    {steam_bypass, steam_axis} =
      step_axis(
        turbine.steam_axis,
        SteamGen.get_outlet(steam_gen),
        turbine.min_steam
      )

    {pressure_bypass, pressure_axis} =
      step_axis(
        turbine.pressure_axis,
        SteamGen.get_pressure(steam_gen),
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
      Valves.set_open_percent(steam_gen.bypass, new)
    end

    %Turbine{turbine | steam_axis: steam_axis, pressure_axis: pressure_axis, bypass: new}
  end

  defp step_axis(axis, current, target) do
    case ControlAxis.step(axis, target, current) do
      {:changed, axis, new, _old} -> {new, axis}
      {:unchanged, axis, old} -> {old, axis}
    end
  end

  @log_module inspect(__MODULE__) |> String.replace("AutoNuke.Operator.", "")
  defp log_prefix(loop), do: "[#{@log_module}.L#{loop}] "

  defp axis_to_bypass(output), do: round(output * 50) + 50
  defp bypass_to_axis(bypass), do: (bypass - 50) / 50

  defp mscv_to_power_level(n) when n in @power_levels, do: n
  defp mscv_to_power_level(n), do: n |> max(@power_levels.first) |> min(@power_levels.last)
end
