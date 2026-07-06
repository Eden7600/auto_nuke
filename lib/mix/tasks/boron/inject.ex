defmodule Mix.Tasks.AutoNuke.Boron.Inject do
  @moduledoc "Inject boron into the core"
  @shortdoc "Inject boron"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator, as: Op

  # How carefully to inject boron (higher = more):
  @easing 3
  # At easing of 3, we start slowing down when boron PPM is
  # within 150 of target, since 50 g/m * 3 = 150.
  # This should allow us to miss some data ticks (which shouldn't happen anyway)
  # and still safely stop at the target.

  @core API.Vessels.core_vessel()

  # Stop if core vessel gauge reaches 2498.
  @max_core_gauge 2498
  # Resume when core vessel gets down to 2490.
  @min_core_gauge 2490
  # Progress bar starts at 100% full:
  @core_gauge_max UI.Vessels.gauge_capacity(@core)
  # Default to the max rate we can inject:
  @max_rate 50

  def run([target]), do: do_run(target)
  def run([target, max_rate]), do: do_run(target, max_rate)

  defp do_run(target, max_rate \\ "#{@max_rate}") do
    UI.init()
    Op.CoreFill.start_link()
    Op.PCSTFill.start_link()

    inject_boron(
      target |> String.to_integer(),
      max_rate |> String.to_integer()
    )

    Op.CoreFill.stop()
    Op.PCSTFill.stop()
  end

  def inject_boron(target, max_rate) when is_integer(target) and is_integer(max_rate) do
    if core_vessel_full(), do: wait_core_vessel_drain()

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
      UI.warn("Core is too full!  Waiting for automatic drain.")
      inject_boron(target, max_rate)
    end
  end

  defp wait_core_vessel_drain do
    UI.console("Coolant System")

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(@core_gauge_max, @min_core_gauge, @core.gauge_units),
      label: "Core",
      current_fn: fn -> API.Vessels.get_fill_gauge(@core) end,
      done_fn: &(&1 < @min_core_gauge)
    )
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
