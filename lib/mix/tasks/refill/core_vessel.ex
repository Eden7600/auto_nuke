defmodule Mix.Tasks.AutoNuke.Refill.CoreVessel do
  @moduledoc "Refills Core Vessel to specified gauge level"
  @shortdoc "Refills Core Vessel"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @core API.Vessels.core_vessel()
  @pcst API.Vessels.primary_cst()
  @pump API.Pumps.primary_circuit()

  @max UI.Vessels.gauge_capacity(@core)

  # I have no idea how 1 kL in the primary CST tank results 
  # in 20M³ in the core vessel, but that's just how it is.
  @primary_cst_factor 20

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target < @max do
    UI.init()
    check_primary_cst_level(target)
    UI.Refill.refill(pump: @pump, vessel: @core, target_level: target)
  end

  defp check_primary_cst_level(core_target) do
    core_missing = core_target - API.Vessels.get_fill_gauge(@core)
    pcst_target = (core_missing / @primary_cst_factor) |> ceil() |> max(0)

    UI.wait(
      "Primary Core Storage Tank",
      "FILL TO #{pcst_target} kL",
      fn -> API.Vessels.get_fill_volume(@pcst) >= pcst_target * 1000 end
    )
  end
end
