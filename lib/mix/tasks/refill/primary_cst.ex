defmodule Mix.Tasks.AutoNuke.Refill.PrimaryCst do
  @moduledoc "Refills Primary Circuit Storage Tank to specified gauge level"
  @shortdoc "Refills Primary CST"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @tank_size 150_000
  @gauge_factor 1000
  @max div(@tank_size, @gauge_factor)

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target <= @max do
    AutoNuke.Tasks.Refill.refill(
      pre_check: &check_valves/0,
      pump_name: "Primary Circuit Pump",
      tank_description: "Primary CST Level",
      pump_get_active: &is_pump_active?/0,
      pump_set_enabled: &set_pump_enabled/1,
      tank_get_level: &get_tank_volume/0,
      target_level: target
    )
  end

  defp check_valves do
    UI.wait(
      "Valve M01",
      "CLOSE",
      fn -> get_valve("M01") == 0 end
    )

    UI.wait(
      "Valve M02",
      "CLOSE",
      fn -> get_valve("M02") == 0 end
    )

    UI.wait(
      "Valve M03",
      "OPEN",
      fn -> get_valve("M03") == 100 end
    )
  end

  @switch "FREIGHT_PUMP_INTERNAL_SWITCH"
  @active "FREIGHT_PUMP_INTERNAL_ACTIVE"
  defp is_pump_active?, do: API.get_boolean(@active)
  defp set_pump_enabled(true), do: API.put(@switch, "True")
  defp set_pump_enabled(false), do: API.put(@switch, "False")

  defp get_tank_volume do
    API.get_float("CORE_PRIMARY_CIRCUIT_COOLING_TANK_VOLUME")
    |> floor()
    |> div(@gauge_factor)
  end

  defp get_valve(key), do: API.get_integer("VALVE_#{key}_OPEN")
end
