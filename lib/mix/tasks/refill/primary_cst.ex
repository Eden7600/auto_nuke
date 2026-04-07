defmodule Mix.Tasks.AutoNuke.Refill.PrimaryCst do
  @moduledoc "Refills Primary Circuit Storage Tank to specified gauge level"
  @shortdoc "Refills Primary CST"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @pump API.Pumps.internal_freight()
  @vessel API.Vessels.primary_cst()
  @max UI.Vessels.gauge_capacity(@vessel)

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target < @max do
    UI.init()
    API.Valves.valve_m01() |> UI.Valves.close()
    API.Valves.valve_m02() |> UI.Valves.close()
    API.Valves.valve_m03() |> UI.Valves.open()
    UI.Refill.refill(pump: @pump, vessel: @vessel, target_level: target)
  end
end
