defmodule Mix.Tasks.AutoNuke.Refill.Condenser do
  @moduledoc "Refills condenser to specified gauge level"
  @shortdoc "Refills condenser"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @pump API.Pumps.condenser_freight()
  @vessel API.Vessels.condenser()
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
