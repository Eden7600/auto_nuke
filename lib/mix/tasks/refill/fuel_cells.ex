defmodule Mix.Tasks.AutoNuke.Refill.FuelCells do
  @shortdoc "Assists in replacing fuel cells"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @moduledoc """
  Assists in replacing fuel cells.  Raises piston, opens hatch, closes once filled.

  Usage: `mix auto_nuke.refill.core [bay...]`

  Possible bay formats:

  - A single bay (e.g. `1`, `2`, etc)
  - A range of bays (`3..5`)
  - All bays (`all`)
  - Some combination of the above, separated by commas or spaces (i.e. multiple args)
  """

  # If we can't verify piston status, wait 5 seconds between hatch requests.
  @unsure_hatch_wait 5000

  def run(args) do
    args
    |> Enum.flat_map(&UI.parse_many_core_bays/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> then(fn bays ->
      UI.init()
      bays |> Enum.each(&refill_bay/1)
    end)
  end

  defp refill_bay(core) do
    unload_bay(core, get_bay_state(core))
    load_bay(core)
  end

  defp unload_bay(core, "INTERIOR") do
    UI.set_wait(
      "Core Bay #{core}",
      "RAISE PISTON",
      fn -> get_bay_state(core) == "EXTERIOR" end,
      fn -> raise_piston(core) end
    )

    unload_bay(core, "EXTERIOR")
  end

  defp unload_bay(core, "EXTERIOR") do
    UI.set_wait(
      "Core Bay #{core}",
      "OPEN HATCH",
      fn -> hatch_open?(core) end,
      fn -> open_hatch(core) end
    )

    UI.wait(
      "Core Bay #{core}",
      "UNLOAD FUEL",
      fn -> get_bay_state(core) == "VACIO" end
    )
  end

  defp unload_bay(core, "VACIO") do
    # We have no way to verify the state of the piston without fuel inserted.
    # So we'll try to raise it, wait a reasonable amount of time, then
    # repeatedly try to open it.
    UI.wait(
      "Core Bay #{core}",
      "RAISE PISTON",
      fn -> raise_piston(core) end
    )

    Process.send_after(self(), :open_hatch, 0)

    UI.wait(
      "Core Bay #{core}",
      "OPEN HATCH",
      fn ->
        if hatch_open?(core) do
          true
        else
          maybe_open_hatch(core)
          false
        end
      end
    )
  end

  defp load_bay(core) do
    UI.wait(
      "Core Bay #{core}",
      "LOAD FUEL",
      fn -> get_bay_state(core) == "EXTERIOR" end
    )

    UI.set_wait(
      "Core Bay #{core}",
      "CLOSE HATCH",
      fn -> !hatch_open?(core) end,
      fn -> close_hatch(core) end
    )
  end

  defp get_bay_state(core), do: API.get_string("CORE_BAY_#{core}_STATE")
  defp raise_piston(core), do: API.put("CORE_BAY_#{core}_FUEL_LOADING", "UNLOAD")

  defp hatch_open?(core), do: API.get_boolean("CORE_BAY_#{core}_HATCH_OPEN")
  defp open_hatch(core), do: API.put("CORE_BAY_#{core}_HATCH", "OPEN")
  defp close_hatch(core), do: API.put("CORE_BAY_#{core}_HATCH", "CLOSE")

  defp maybe_open_hatch(core) do
    receive do
      :open_hatch ->
        open_hatch(core)
        Process.send_after(self(), :open_hatch, @unsure_hatch_wait)
    after
      0 -> :noop
    end
  end
end
