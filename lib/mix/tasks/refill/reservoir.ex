defmodule Mix.Tasks.AutoNuke.Refill.Reservoir do
  @moduledoc "Refills external reservoir to specified gauge level"
  @shortdoc "Refills external reservoir"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @pump API.Pumps.external_freight()
  @vessel API.Vessels.reservoir()
  @max UI.Vessels.gauge_capacity(@vessel)

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target < @max do
    UI.init()
    UI.Refill.refill(pump: @pump, vessel: @vessel, target_level: target)
  end
end
