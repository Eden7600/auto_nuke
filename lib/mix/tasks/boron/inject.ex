defmodule Mix.Tasks.AutoNuke.Boron.Inject do
  @moduledoc "Inject boron into the core"
  @shortdoc "Inject boron"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  # How carefully to inject boron (higher = more):
  @easing 3
  # At easing of 3, we start slowing down when boron PPM is
  # within 150 of target, since 50 g/m * 3 = 150.
  # This should allow us to miss some data ticks (which shouldn't happen anyway)
  # and still safely stop at the target.

  @core API.Vessels.core_vessel()
  @pcst API.Vessels.primary_cst()
  @rcv API.Valves.rcv()
  @cst_drain API.Valves.cst_drain()

  # Stop when core vessel gauge reaches 2490.
  @max_core_gauge 2490
  # Resume when core vessel gets down to 2470.
  # Note that there will be some delay in closing the RCV, 
  # so the actual stop point will be lower than this.
  @min_core_gauge 2470
  # Progress bar starts at 100% full:
  @core_gauge_max UI.Vessels.gauge_capacity(@core)
  # Also drain the primary CST if it's more than 95% full:
  @max_pcst_ratio 0.95
  # Default to the max rate we can inject:
  @max_rate 50

  def run([target]), do: do_run(target)
  def run([target, max_rate]), do: do_run(target, max_rate)

  defp do_run(target, max_rate \\ "#{@max_rate}") do
    UI.init()

    inject_boron(
      target |> String.to_integer(),
      max_rate |> String.to_integer()
    )
  end

  def inject_boron(target, max_rate) when is_integer(target) and is_integer(max_rate) do
    if core_vessel_full(), do: drain_core_vessel()

    UI.console("Chemical Treatment")

    UI.set_wait_unless(
      "Boron Injection",
      "BEGIN",
      fn -> get_boron_ppm() >= target end,
      fn -> get_boron_rate() > 0 end,
      fn -> adjust_boron_injection(target, max_rate) end
    )

    try do
      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.target(0, target, " ppm", 1),
        label: "Boron",
        current_fn: fn -> adjust_boron_injection(target, max_rate) end,
        done_fn: fn ppm ->
          case core_vessel_full() do
            true -> :abort
            false -> ppm >= target
          end
        end
      )
    after
      set_boron_rate(0)
    end

    if get_boron_ppm() < target do
      UI.warn("Core is too full!  Performing automatic drain.")
      inject_boron(target, max_rate)
    end
  end

  defp drain_core_vessel do
    UI.console("Drain & Vent Valves")

    valves =
      case API.Vessels.get_fill_ratio(@pcst) > @max_pcst_ratio do
        true -> [@rcv, @cst_drain]
        false -> [@rcv]
      end

    try do
      valves |> Enum.each(&UI.Valves.set_actuator(&1, "OPEN"))

      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.target(@core_gauge_max, @min_core_gauge, @core.gauge_units),
        label: "Core",
        current_fn: fn -> API.Vessels.get_fill_gauge(@core) end,
        done_fn: &(&1 < @min_core_gauge)
      )
    after
      valves |> Enum.each(&UI.Valves.set_actuator(&1, "CLOSE"))
      valves |> Enum.each(&UI.Valves.wait_until_closed/1)
      valves |> Enum.each(&UI.Valves.set_actuator(&1, "OFF"))
    end
  end

  defp adjust_boron_injection(target, max_rate) do
    ppm = get_boron_ppm()

    rate =
      if ppm >= target do
        0
      else
        ((target - ppm) / @easing)
        |> ceil()
        |> min(max_rate)
      end

    set_boron_rate(rate)
    ppm
  end

  defp core_vessel_full, do: API.Vessels.get_fill_gauge(@core) >= @max_core_gauge
  defp get_boron_ppm, do: API.get_float("CHEM_BORON_PPM")
  defp set_boron_rate(rate), do: API.put("CHEM_BORON_DOSAGE_ORDERED_RATE", rate)
  defp get_boron_rate, do: API.get_float("CHEM_BORON_DOSAGE_ACTUAL")
end
