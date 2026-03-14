defmodule Mix.Tasks.AutoNuke.Condenser.Refill do
  @moduledoc "Refills condenser to specified percentage"
  @shortdoc "Refills condenser"

  use Mix.Task
  alias AutoNuke.TaskUI, as: UI

  @tank_size 360_000
  @default_target 0.5

  def run([]), do: refill(@default_target)

  def refill(target) when target >= 0.0 and target <= 1.0 do
    {:ok, _} = Application.ensure_all_started([:req])

    target_volume = @tank_size * target

    if get_volume() <= target_volume do
      set_switch(true)

      UI.progress_loop(
        label: "Condenser Level",
        fetch: &get_volume/0,
        max: round(target_volume)
      )
    end

    set_switch(false)
    IO.puts("Done!")
  end

  defp get_volume, do: AutoNuke.API.get_float("CONDENSER_VOLUME") |> round()

  @switch "FREIGHT_PUMP_CONDENSER_SWITCH"
  defp set_switch(true), do: AutoNuke.API.put(@switch, "True")
  defp set_switch(false), do: AutoNuke.API.put(@switch, "False")
end
