defmodule Mix.Tasks.AutoNuke.Refill.Condenser do
  @moduledoc "Refills condenser to specified gauge level"
  @shortdoc "Refills condenser"

  use Mix.Task
  alias AutoNuke.API

  @tank_size 360_000
  @gauge_factor 100
  @max div(@tank_size, @gauge_factor)

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target <= @max do
    AutoNuke.Tasks.Refill.refill(
      pump_name: "Secondary Circuit Freight Pump",
      tank_description: "Condenser Level",
      pump_get_active: &is_pump_active?/0,
      pump_set_enabled: &set_pump_enabled/1,
      tank_get_level: &get_tank_volume/0,
      target_level: target
    )
  end

  @switch "FREIGHT_PUMP_CONDENSER_SWITCH"
  @active "FREIGHT_PUMP_CONDENSER_ACTIVE"
  defp is_pump_active?, do: API.get_boolean(@active)
  defp set_pump_enabled(true), do: API.put(@switch, "True")
  defp set_pump_enabled(false), do: API.put(@switch, "False")

  defp get_tank_volume do
    API.get_float("CONDENSER_VOLUME")
    |> floor()
    |> div(@gauge_factor)
  end
end
