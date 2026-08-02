defmodule AutoNuke.Tui.Drills do
  @moduledoc """
  The game's `FUN_*` chaos hooks, packaged as drills for stress-testing
  the operators.

  The game gates these behind an in-game confirmation: the first action
  requests enablement (`FUN_REQUEST_ENABLE`), which pops a prompt inside
  Nucleares. Until accepted, every drill returns the game's own
  "subset is not enabled" error, which we surface verbatim.
  """

  alias AutoNuke.API

  def items do
    [
      %{
        label: "Enable drills (confirm in-game!)",
        params: [],
        run: fn _ -> press("FUN_REQUEST_ENABLE") end
      },
      %{label: "Pump jam", params: [], run: fn _ -> press("FUN_PUMP_JAM") end},
      %{label: "Breaker trip", params: [], run: fn _ -> press("FUN_BREAKER_TRIP") end},
      %{
        label: "Toggle a random switch",
        params: [],
        run: fn _ -> press("FUN_TOGGLE_RANDOM_SWITCH") end
      },
      %{label: "Fire drill", params: [], run: fn _ -> press("FUN_FIRE_DRILL") end},
      %{label: "Iodine spill", params: [], run: fn _ -> press("FUN_IODINE_SPILL") end},
      %{label: "Xenon spill", params: [], run: fn _ -> press("FUN_XENON_SPILL") end},
      %{label: "Oil spill", params: [], run: fn _ -> press("FUN_OIL_SPILL") end},
      %{label: "Trigger an audit", params: [], run: fn _ -> press("FUN_TRIGGER_AUDIT") end},
      %{label: "Bank robbery", params: [], run: fn _ -> press("FUN_BANK_ROBBERY") end},
      %{
        label: "Sabotage the AO (once)",
        params: [],
        run: fn _ -> press("FUN_AO_SABOTAGE_ONCE") end
      },
      %{
        label: "Decrease core integrity",
        params: [],
        run: fn _ -> press("FUN_DECREASE_INTEGRITY") end
      },
      %{
        label: "Set weather",
        params: [%{label: "Weather", hint: "e.g. RAIN, STORM, CLEAR"}],
        run: fn [weather] -> put("FUN_WEATHER_CONTROL", String.upcase(weather)) end
      },
      %{
        label: "Show in-game message",
        params: [%{label: "Message", hint: "shown to the player"}],
        run: fn [message] -> put("FUN_SHOW_MESSAGE", message) end
      }
    ]
  end

  defp press(variable), do: put(variable, "PRESS")

  defp put(variable, value) do
    # The game often answers with what actually happened ("Pump
    # BC_2_NUCLEO_CARGA jammed!") — surface that instead of a bare ok.
    case API.put_with_reply(variable, value) do
      {:ok, body} when body in ["", "null"] -> :ok
      {:ok, body} -> {:ok, body}
    end
  rescue
    e -> {:error, drill_error(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  # The game's 412 "subset not enabled" arrives as our API error; keep the
  # useful part.
  defp drill_error(%{message: message}) do
    cond do
      message =~ "not enabled" -> "Not enabled — run the enable drill and confirm in-game."
      true -> message
    end
  end

  defp drill_error(e), do: Exception.message(e)
end
