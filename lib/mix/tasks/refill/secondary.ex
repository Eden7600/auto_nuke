defmodule Mix.Tasks.AutoNuke.Refill.Secondary do
  @moduledoc "Refills specified steam generator to specified gauge level"
  @shortdoc "Refills steam generator"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @max API.Vessels.steam_generator(1) |> UI.Vessels.gauge_capacity()

  def run([target | loops]) do
    target = target |> String.to_integer()

    UI.init()

    loops
    |> Enum.map(&UI.parse_loop/1)
    |> Enum.map(&API.SteamGen.for_loop/1)
    |> refill(target)
  end

  def refill(steam_gens, target) when target >= 0 and target < @max do
    steam_gens |> Enum.each(&UI.Pumps.start(&1.pump))

    label =
      case steam_gens do
        [sg] -> "SG 0#{sg.loop}"
        more -> "SGs #{more |> Enum.map(&"0#{&1.loop}") |> Enum.join("+")}"
      end

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.percent(),
      label: label,
      current_fn: fn ->
        steam_gens
        |> Enum.map(&adjust_and_percent(&1, target))
        |> Statistex.average()
      end,
      done_fn: &(&1 >= 100)
    )
  end

  defp adjust_and_percent(steam_gen, target) do
    gauge = API.Vessels.get_fill_gauge(steam_gen.vessel)

    # Set pump speed to half of remaining gauge level:
    (target - gauge)
    |> Kernel./(2)
    |> ceil()
    |> min(100)
    |> then(&API.Pumps.set_speed(steam_gen.pump, &1))

    # Return percent completion:
    (gauge / target * 100)
    |> min(100.0)
  end
end
