defmodule Mix.Tasks.AutoNuke.Refill.CorePoolStorage do
  @moduledoc "Refills Core Pool Storage Tank to specified gauge level"
  @shortdoc "Refills Core Pool Storage"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @tank_size 80_000
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
      pump_name: "Internal Freight Pump",
      tank_description: "Core Pool Storage Level",
      pump_get_active: &is_pump_active?/0,
      pump_set_enabled: &set_pump_enabled/1,
      tank_get_level: &get_tank_volume/0,
      target_level: target
    )
  end

  defp check_valves do
    [M01: false, M02: true, M03: false]
    |> Enum.each(fn {key, open} ->
      verb = if open, do: "OPEN", else: "CLOSE"
      setting = if open, do: 100, else: 0

      UI.wait(
        "Valve #{key}",
        verb,
        fn -> get_valve(key) == setting end
      )
    end)
  end

  @switch "FREIGHT_PUMP_INTERNAL_SWITCH"
  @active "FREIGHT_PUMP_INTERNAL_ACTIVE"
  defp is_pump_active?, do: API.get_boolean(@active)
  defp set_pump_enabled(true), do: API.put(@switch, "True")
  defp set_pump_enabled(false), do: API.put(@switch, "False")

  defp get_tank_volume do
    API.get_float("CORE_POOL_COOLANT_TANK_VOLUME")
    |> floor()
    |> div(@gauge_factor)
  end

  defp get_valve(key), do: API.get_integer("VALVE_#{key}_OPEN")
end
