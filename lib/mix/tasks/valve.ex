defmodule Mix.Tasks.AutoNuke.Valve do
  @shortdoc "Opens and closes valves"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @base_valves %{
    # Core to primary pump
    "A1" => "VALVULA_ENTRADA_NUCLEO_01",
    "B1" => "VALVULA_ENTRADA_NUCLEO_02",
    "C1" => "VALVULA_ENTRADA_NUCLEO_03",
    # Steam generator return to core
    "A2" => "VALVULA_SALIDA_NUCLEO_01",
    "B2" => "VALVULA_SALIDA_NUCLEO_02",
    "C2" => "VALVULA_SALIDA_NUCLEO_03",
    # Primary pump to steam generator
    "A3" => "VALVULA_ENTRE_BC_Y_EVA_01",
    "B3" => "VALVULA_ENTRE_BC_Y_EVA_02",
    "C3" => "VALVULA_ENTRE_BC_Y_EVA_03",
    # Steam generator to turbine (MSCV)
    "A4" => "VALVULA_ENTRADA_TURBINA_01",
    "B4" => "VALVULA_ENTRADA_TURBINA_02",
    "C4" => "VALVULA_ENTRADA_TURBINA_03",
    # Turbine to condenser
    "A5" => "VALVULA_ENTRADA_CONDENSADOR_01",
    "B5" => "VALVULA_ENTRADA_CONDENSADOR_02",
    "C5" => "VALVULA_ENTRADA_CONDENSADOR_03",
    # Condenser to secondary pump
    "A6" => "VALVULA_SALIDA_CONDENSADOR_01",
    "B6" => "VALVULA_SALIDA_CONDENSADOR_02",
    "C6" => "VALVULA_SALIDA_CONDENSADOR_03"
  }

  @other_valves %{
    # Other valves with actuators
    "PZR COOLING" => "Valvula_Pressurizer_Spray",
    "PZR VENT" => "Valvula_Pressurizer_Vent",
    "RCV" => "Valvula_Descargar_REF",
    "CST DRAIN" => "Valvula_Purgar_Coolant"
  }

  @valves Map.merge(@base_valves, @other_valves)

  @groups %{
    "A*" => 1..6 |> Enum.map(&"A#{&1}"),
    "B*" => 1..6 |> Enum.map(&"B#{&1}"),
    "C*" => 1..6 |> Enum.map(&"C#{&1}"),
    "OTHER" => ["PZR COOLING", "PZR VENT", "RCV", "CST DRAIN"]
  }

  @moduledoc """
  Opens and closes valves with electronic actuators.

  Usage: `mix auto_nuke.valve <valve> <open|close>`

  Possible valves:

  - A1 .. A6
  - B1 .. B6
  - C1 .. C6
  #{@other_valves |> Map.keys() |> Enum.map(&"- #{&1}") |> Enum.join("\n")}

  Possible valve groups:

  #{@groups |> Enum.map(fn {k, v} -> "- `#{k}` — #{v |> Enum.join(", ")}" end) |> Enum.join("\n")}
  """

  def run([name, action]) do
    name = name |> String.replace(~r{[^a-zA-Z0-9*]+}, " ") |> String.upcase()

    run_group(name, action) || run_valve(name, action) || raise "Unknown valve or group: #{name}"
  end

  defp run_group(name, action) do
    case Map.fetch(@groups, name) do
      {:ok, names} ->
        names |> Enum.each(&run_valve(&1, action))
        true

      :error ->
        false
    end
  end

  defp run_valve(name, action) do
    case Map.fetch(@valves, name) do
      {:ok, key} ->
        case action do
          "open" -> do_valve(name, key, "OPEN", &get_open_percent/1)
          "close" -> do_valve(name, key, "CLOSE", &get_close_percent/1)
        end

        true

      :error ->
        false
    end
  end

  defp do_valve(name, key, action, fetch_fn) do
    {:ok, _} = Application.ensure_all_started([:req])

    UI.set_wait(
      "Valve #{name} Actuator",
      action,
      fn -> get_actuator(key) == action end,
      fn -> set_actuator(key, action) end
    )

    UI.progress_loop(
      label: "Valve #{name}",
      fetch: fn -> fetch_fn.(key) end,
      max: 100
    )

    UI.set_wait(
      "Valve #{name} Actuator",
      "OFF",
      fn -> get_actuator(key) == "OFF" end,
      fn -> set_actuator(key, "OFF") end
    )
  end

  defp valve_data(key) do
    API.get_json("VALVE_PANEL_JSON")
    |> Map.fetch!("valves")
    |> Map.fetch!(key)
  end

  defp get_actuator(key), do: valve_data(key) |> Map.fetch!("Actuator")
  defp get_open_percent(key), do: valve_data(key) |> Map.fetch!("Value") |> round()
  defp get_close_percent(key), do: 100 - get_open_percent(key)

  defp set_actuator(key, action) do
    API.put("VALVE_#{action}", key)
  end
end
