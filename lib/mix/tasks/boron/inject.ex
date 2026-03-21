defmodule Mix.Tasks.AutoNuke.Boron.Inject do
  @moduledoc "Inject boron into the core"
  @shortdoc "Inject boron"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  # Default target PPM for boron injection:
  @default_target 2800
  # How carefully to inject boron (higher = more):
  @easing 3
  # At easing of 3, we start slowing down when boron PPM is
  # within 150 of target, since 50 g/m * 3 = 150.
  # This should allow us to miss some data ticks (which shouldn't happen anyway)
  # and still safely stop at the target.

  def run([target]) do
    target
    |> String.to_integer()
    |> inject_boron()
  end

  def run([]) do
    inject_boron(@default_target)
  end

  def inject_boron(target) when is_integer(target) do
    Application.put_env(:auto_nuke, :start, false)
    {:ok, _} = Application.ensure_all_started([:auto_nuke, :logger, :pubsub])

    UI.console("Chemical Treatment")

    init_boron = get_boron_ppm()

    UI.set_wait_unless(
      "Boron Injection",
      "BEGIN",
      fn -> init_boron >= target end,
      fn -> get_boron_ppm() > init_boron end,
      fn -> get_boron_ppm() |> set_boron_injection(target) end
    )

    UI.progress_loop(
      label: "Boron PPM",
      fetch: fn ->
        ppm = get_boron_ppm()
        set_boron_injection(ppm, target)
        ppm |> Float.round(1)
      end,
      max: target
    )
  end

  defp set_boron_injection(ppm, target) do
    rate =
      if ppm >= target do
        0
      else
        ((target - ppm) / @easing)
        |> ceil()
        |> min(50)
      end

    API.put("CHEM_BORON_DOSAGE_ORDERED_RATE", rate)
  end

  def get_boron_ppm do
    API.get_float("CHEM_BORON_PPM")
  end
end
