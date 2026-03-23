defmodule Mix.Tasks.AutoNuke.Refill.Internal do
  @moduledoc "Refills multiple tanks with the Internal Freight Pump"
  @shortdoc "Refills M01/M02/M03"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @pcst_size 150_000
  @core_size 80_000
  @target_percent 100

  def run([]) do
    AutoNuke.Tasks.Refill.refill(
      pre_check: &check_valves/0,
      pump_name: "Internal Freight Pump",
      tank_description: "Core Pool + Primary CST",
      pump_get_active: &is_pump_active?/0,
      pump_set_enabled: &set_pump_enabled/1,
      tank_get_level: &get_percent_full/0,
      target_level: @target_percent
    )
  end

  defp check_valves do
    UI.set(
      "Valve M01",
      "OPEN IF NEEDED"
    )

    if ceil(get_core_percent_full()) < @target_percent do
      UI.wait(
        "Valve M02",
        "OPEN",
        fn -> valve_open?("M02") end
      )
    else
      UI.wait(
        "Valve M02",
        "NOT NEEDED",
        fn -> true end
      )
    end

    if ceil(get_pcst_percent_full()) < @target_percent do
      UI.wait(
        "Valve M03",
        "OPEN",
        fn -> valve_open?("M03") end
      )
    else
      UI.wait(
        "Valve M03",
        "NOT NEEDED",
        fn -> true end
      )
    end
  end

  @switch "FREIGHT_PUMP_INTERNAL_SWITCH"
  @active "FREIGHT_PUMP_INTERNAL_ACTIVE"
  defp is_pump_active?, do: API.get_boolean(@active)
  defp set_pump_enabled(true), do: API.put(@switch, "True")
  defp set_pump_enabled(false), do: API.put(@switch, "False")

  defp get_core_percent_full,
    do: API.get_float("CORE_POOL_COOLANT_TANK_VOLUME") / @core_size * 100

  defp get_pcst_percent_full,
    do: API.get_float("CORE_PRIMARY_CIRCUIT_COOLING_TANK_VOLUME") / @pcst_size * 100

  defp get_percent_full do
    [
      get_core_percent_full(),
      get_pcst_percent_full()
    ]
    |> Statistex.average()
    |> ceil()
  end

  defp valve_open?(key), do: API.get_integer("VALVE_#{key}_OPEN") == 100
end
