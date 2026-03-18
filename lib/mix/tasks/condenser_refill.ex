defmodule Mix.Tasks.AutoNuke.Condenser.Refill do
  @moduledoc "Refills condenser to specified percentage"
  @shortdoc "Refills condenser"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @tank_size 360_000
  @max div(@tank_size, 100)

  def run([target]) do
    target
    |> String.to_integer()
    |> refill()
  end

  def refill(target) when target >= 0 and target <= @max do
    {:ok, _} = Application.ensure_all_started([:req])

    try do
      UI.set_wait_unless(
        "Secondary Circuit Freight Pump",
        "ON",
        fn -> get_volume() >= target end,
        fn -> get_active() end,
        fn -> set_switch(true) end
      )

      UI.progress_loop(
        label: "Condenser Level",
        fetch: &get_volume/0,
        max: target
      )
    after
      UI.set_wait(
        "Secondary Circuit Freight Pump",
        "OFF",
        fn -> !get_active() end,
        fn -> set_switch(false) end
      )

      set_switch(false)
    end

    IO.puts("Done!")
  end

  defp get_volume, do: API.get_float("CONDENSER_VOLUME") |> floor() |> div(100)

  @switch "FREIGHT_PUMP_CONDENSER_SWITCH"
  defp set_switch(true), do: API.put(@switch, "True")
  defp set_switch(false), do: API.put(@switch, "False")

  @active "FREIGHT_PUMP_CONDENSER_ACTIVE"
  defp get_active, do: API.get_boolean(@active)
end
