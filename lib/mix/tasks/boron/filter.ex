defmodule Mix.Tasks.AutoNuke.Boron.Filter do
  @moduledoc "Filter boron out of the core"
  @shortdoc "Filter boron"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  def run([target]) do
    target
    |> String.to_integer()
    |> maybe_filter_boron()
  end

  defp maybe_filter_boron(target) when is_integer(target) do
    {:ok, _} = Application.ensure_all_started([:req])

    ppm = get_boron_ppm()
    excess = ppm - target

    if excess > 0 do
      filter_boron(target, excess)
    else
      UI.success("Boron PPM is #{ppm}.")
    end
  end

  defp filter_boron(target, excess) do
    UI.console("Chemical Treatment")

    UI.set("Ion Exchange Inlet", "OPEN")
    UI.set("Ion Exchange Outlet", "OPEN")
    IO.gets("Press enter when valves are opened ...")

    try do
      set_pump_speed(1)

      UI.set_wait_unless(
        "Ion Exchange",
        "START",
        fn -> get_boron_ppm() <= target end,
        fn -> get_pump_speed() > 0 end,
        fn -> get_boron_ppm() |> adjust_pump_speed(target) end
      )

      UI.progress_loop(
        label: "Boron Decrease",
        fetch: fn ->
          ppm = get_boron_ppm()
          adjust_pump_speed(ppm, target)
          (target + excess - ppm) |> Float.round(1)
        end,
        max: excess |> Float.round(1)
      )
    after
      UI.set_wait(
        "Ion Exchange",
        "STOP",
        fn -> get_pump_speed() == 0 end,
        fn -> set_pump_speed(0) end
      )
    end
  end

  defp get_pump_speed, do: API.get_float("CHEM_BORON_FILTER_ACTUAL")
  defp set_pump_speed(speed), do: API.put("CHEM_BORON_FILTER_ORDERED_SPEED", speed)

  defp adjust_pump_speed(ppm, target) do
    if ppm <= target do
      0
    else
      (ppm - target)
      |> ceil()
      |> min(100)
    end
    |> set_pump_speed()
  end

  def get_boron_ppm do
    API.get_float("CHEM_BORON_PPM")
  end
end
