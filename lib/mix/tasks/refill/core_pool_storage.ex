defmodule Mix.Tasks.AutoNuke.Refill.CorePoolStorage do
  @moduledoc "Refills Core Pool Storage Tank to specified gauge level"
  @shortdoc "Refills Core Pool Storage"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @pump API.Pumps.internal_freight()
  @vessel API.Vessels.core_pool_storage()
  @max UI.Vessels.gauge_capacity(@vessel)

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target < @max do
    UI.init()
    API.Valves.valve_m01() |> UI.Valves.close()
    API.Valves.valve_m02() |> UI.Valves.open()
    API.Valves.valve_m03() |> UI.Valves.close()
    UI.Refill.refill(pump: @pump, vessel: @vessel, target_level: target)
  end
end
