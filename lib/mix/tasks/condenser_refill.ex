defmodule Mix.Tasks.AutoNuke.Condenser.Refill do
  @moduledoc "Refills condenser to specified percentage"
  @shortdoc "Refills condenser"

  use Mix.Task

  @tank_size 360_000
  @default_target 0.5

  def run([]), do: refill(@default_target)

  def refill(target) when target >= 0.0 and target <= 1.0 do
    {:ok, _} = Application.ensure_all_started([:req])

    set_switch(true)
    loop_until_full(target * @tank_size)
    set_switch(false)
  end

  defp loop_until_full(target) do
    if get_level() >= target do
      :ok
    else
      Process.sleep(100)
      loop_until_full(target)
    end
  end

  defp get_level, do: AutoNuke.API.get_float("CONDENSER_VOLUME")

  @switch "FREIGHT_PUMP_CONDENSER_SWITCH"
  defp set_switch(true), do: AutoNuke.API.put(@switch, "True")
  defp set_switch(false), do: AutoNuke.API.put(@switch, "False")
end
