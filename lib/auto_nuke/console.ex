defmodule AutoNuke.Console do
  alias AutoNuke.Operator, as: Op

  def core_status do
    [
      core_temp: Op.ControlRods.get_core_temp(),
      target: Op.ControlRods.get_target(),
      rods: Op.ControlRods.get_rods() |> Enum.map(fn {b, r} -> {:"_#{b}", r} end),
      boron: boron_status()
    ]
  end

  def boron_status do
    [
      ppm: Op.BoronLevel.get_boron_ppm(),
      dosing: Op.BoronLevel.get_dosing_rate(),
      filter: Op.BoronLevel.get_filter_rate()
    ]
  end

  def status do
    [
      core: core_status()
    ]
  end
end
