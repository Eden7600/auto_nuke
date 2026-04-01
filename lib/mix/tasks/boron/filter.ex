defmodule Mix.Tasks.AutoNuke.Boron.Filter do
  @moduledoc "Filter boron out of the core"
  @shortdoc "Filter boron"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  def run([target]) do
    maybe_filter_boron(
      target |> String.to_integer(),
      100
    )
  end

  def run([target, max_speed]) do
    maybe_filter_boron(
      target |> String.to_integer(),
      max_speed |> String.to_integer()
    )
  end

  defp maybe_filter_boron(target, max_speed)
       when is_integer(target) and is_integer(max_speed) and max_speed in 1..100 do
    {:ok, _} = Application.ensure_all_started([:req])

    ppm = get_boron_ppm()
    excess = ppm - target

    if excess > 0 do
      filter_boron(target, excess, max_speed)
    else
      UI.success("Boron PPM is #{ppm}.")
    end
  end

  defp filter_boron(target, excess, max_speed) do
    UI.console("Chemical Treatment")

    UI.wait("Ion Exchange Inlet", "OPEN", &ion_inlet_open?/0)
    UI.wait("Ion Exchange Outlet", "OPEN", &ion_outlet_open?/0)

    try do
      set_pump_speed(1)

      UI.set_wait_unless(
        "Ion Exchange",
        "START",
        fn -> get_boron_ppm() <= target end,
        fn -> get_pump_speed() > 0 end,
        fn -> get_boron_ppm() |> adjust_pump_speed(target, max_speed) end
      )

      UI.progress_loop(
        label: "Boron Decrease",
        fetch: fn ->
          ppm = get_boron_ppm()
          adjust_pump_speed(ppm, target, max_speed)
          (target + excess - ppm) |> Float.round(1)
        end,
        max: excess |> round()
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

  defp adjust_pump_speed(ppm, target, max_speed) do
    if ppm <= target do
      0
    else
      (ppm - target)
      |> ceil()
      |> min(max_speed)
    end
    |> set_pump_speed()
  end

  def get_boron_ppm do
    API.get_float("CHEM_BORON_PPM")
  end

  defp valve_data(key) do
    API.get_json("VALVE_PANEL_JSON")
    |> Map.fetch!("valves")
    |> Map.fetch!(key)
  end

  defp valve_open?(key) do
    valve_data(key)
    |> Map.fetch!("State")
    |> Map.fetch!("IsOpened")
  end

  defp ion_inlet_open?, do: valve_open?("Core_Valve_01")
  defp ion_outlet_open?, do: valve_open?("Core_Valve_02")
end
