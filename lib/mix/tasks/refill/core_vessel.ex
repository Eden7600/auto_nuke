defmodule Mix.Tasks.AutoNuke.Refill.CoreVessel do
  @moduledoc "Refills Core Vessel to specified gauge level"
  @shortdoc "Refills Core Vessel"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @tank_size 2500
  # I have no idea how 1L in the primary CST tank results 
  # in 20M³ in the core vessel, but that's just how it is.
  @primary_cst_factor 20

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target <= @tank_size do
    AutoNuke.Tasks.Refill.refill(
      pre_check: fn -> check_primary_cst_level(target) end,
      pump_name: "Primary Circuit Pump",
      tank_description: "Core Vessel Level",
      pump_get_active: &is_pump_active?/0,
      pump_set_enabled: &set_pump_enabled/1,
      tank_get_level: &get_tank_volume/0,
      target_level: target
    )
  end

  @switch "FREIGHT_PUMP_FEEDWATER_SWITCH"
  @active "FREIGHT_PUMP_FEEDWATER_ACTIVE"
  defp is_pump_active?, do: API.get_boolean(@active)
  defp set_pump_enabled(true), do: API.put(@switch, "True")
  defp set_pump_enabled(false), do: API.put(@switch, "False")

  defp get_tank_volume do
    API.get_float("COOLANT_CORE_PRIMARY_LOOP_LEVEL")
    |> Kernel.*(@tank_size / 100)
    |> floor()
  end

  defp check_primary_cst_level(core_target) do
    core_missing = (core_target - get_tank_volume()) |> max(0)
    pcst_target = (core_missing / @primary_cst_factor) |> ceil()

    UI.wait(
      "Primary Core Storage Tank",
      "FILL TO #{pcst_target} kL",
      fn -> get_primary_cst_level() >= pcst_target end
    )
  end

  defp get_primary_cst_level do
    API.get_float("CORE_PRIMARY_CIRCUIT_COOLING_TANK_VOLUME")
  end
end
