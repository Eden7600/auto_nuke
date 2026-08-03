defmodule Mix.Tasks.AutoNuke.Refuel do
  @shortdoc "Guided reactor refueling"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias Mix.Tasks.AutoNuke.Refill

  @moduledoc """
  Guided refueling of the reactor. Automates everything the webserver can
  reach; the crane itself has no API, so the actual cell swaps are yours.

      mix auto_nuke.refuel [bays]

  - `bays` — `spent` (default: loaded cells under #{25}% fissionable),
    `all` (every bay, including empty ones needing a first cell), or
    explicit bays (`1`, `3..5`, `1,4`).

  The task checks the reactor is safely shut down, prints a fuel report,
  drains the core pool to the working level, then walks each bay through
  raise piston, open hatch, your crane work, and close hatch, before
  refilling the core pool.

  Pistons are deliberately left raised: lowering one inserts its fuel into
  the core, which is a startup action, not a refueling one.
  """

  # Loaded cells below this fissionable % count as spent:
  @spent_threshold 25.0
  # Refuse to open the core while it's warmer than this:
  @max_core_temp 99.0

  # The game requires the pool below the top of the hatch to open it;
  # 50% is that level, so it isn't a choice worth offering.
  @pool_working_level "50"
  @pool_full_level "100"

  def run([]), do: refuel(:spent)
  def run([bays]), do: refuel(parse_bays(bays))

  defp parse_bays("spent"), do: :spent
  defp parse_bays("auto"), do: :spent
  defp parse_bays("all"), do: :all
  defp parse_bays(arg), do: UI.parse_many_core_bays(arg)

  def refuel(bay_selection) do
    UI.init()
    UI.log_to_file("startup.log")

    check_reactor_off()

    report = fuel_report()
    bays = select_bays(bay_selection, report)

    UI.console("Reactor Core")
    print_report(report, bays)

    if bays == [] do
      Mix.raise(
        "No bays to refuel (spent = loaded cells under #{@spent_threshold}% fissionable). " <>
          "Use `all` to cycle every bay, including empty ones."
      )
    end

    # Hatches won't open with the pool above the top of the hatch.
    Refill.CorePool.run([@pool_working_level])

    Enum.each(bays, &Refill.FuelCells.refill_bay/1)

    # Every hatch is shut — safe to refill. The pistons stay RAISED:
    # lowering them inserts the fuel into the core, which is starting the
    # reactor. That belongs to startup, never to refueling.
    UI.console("Core Pool")
    Refill.CorePool.run([@pool_full_level])

    UI.success("Refueling complete: bays #{Enum.join(bays, ", ")}.")
    UI.notice("Pistons remain raised — startup lowers them when it loads fuel.")
  end

  # -- Safety -----------------------------------------------------------------

  defp check_reactor_off do
    UI.console("Safety Checks")

    UI.test("Criticality", fn ->
      if API.get_boolean("CORE_CRITICAL_MASS_REACHED"), do: :fail, else: :pass
    end)
    |> passed!("Reactor has critical mass — shut it down before refueling.")

    UI.test("Control Rods", fn ->
      if API.get_float("RODS_POS_ACTUAL") >= 99.0, do: :pass, else: :fail
    end)
    |> passed!("Control rods are not fully inserted.")

    UI.test("Core Temperature", fn ->
      if API.get_float("CORE_TEMP") <= @max_core_temp, do: :pass, else: :fail
    end)
    |> passed!("Core is above #{@max_core_temp}°C — let it cool before opening.")
  end

  defp passed!(:pass, _message), do: :ok
  defp passed!(:fail, message), do: Mix.raise(message)

  # -- Fuel report ------------------------------------------------------------

  defp bay_state(bay), do: API.get_string("CORE_BAY_#{bay}_STATE")

  defp fuel_report do
    for bay <- 1..9,
        state = bay_state(bay),
        state in ["INTERIOR", "EXTERIOR", "VACIO"] do
      %{
        bay: bay,
        state: state,
        fissionable: API.get_float("CORE_FUEL_#{bay}_FISSIONABLE")
      }
    end
  end

  # Loaded cells that are worn out.
  defp select_bays(:spent, report) do
    for %{bay: bay, state: state, fissionable: f} <- report,
        state != "VACIO" and f < @spent_threshold,
        do: bay
  end

  # Every installed bay — including empty ones, which are exactly the bays
  # that need a cell putting in.
  defp select_bays(:all, report) do
    for %{bay: bay} <- report, do: bay
  end

  defp select_bays(bays, report) when is_list(bays) do
    known = report |> Enum.map(& &1.bay) |> MapSet.new()

    case Enum.reject(bays, &(&1 in known)) do
      [] -> bays
      missing -> Mix.raise("Unknown or uninstalled bays: #{Enum.join(missing, ", ")}")
    end
  end

  defp print_report(report, selected) do
    Enum.each(report, fn %{bay: bay, state: state, fissionable: f} ->
      status =
        cond do
          state == "VACIO" -> "EMPTY"
          bay in selected -> "#{format_pct(f)} — REPLACE"
          f < @spent_threshold -> "#{format_pct(f)} (spent)"
          true -> format_pct(f)
        end

      UI.set("Bay #{bay} Fuel", status)
    end)
  end

  defp format_pct(f), do: "#{:erlang.float_to_binary(f / 1, decimals: 1)}% fissionable"
end
