defmodule Mix.Tasks.AutoNuke.Valve do
  @shortdoc "Opens and closes valves"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @base_valves %{
    # Core to primary pump
    "A1" => API.Valves.valve_a1(),
    "B1" => API.Valves.valve_b1(),
    "C1" => API.Valves.valve_c1(),
    # Steam generator return to core
    "A2" => API.Valves.valve_a2(),
    "B2" => API.Valves.valve_b2(),
    "C2" => API.Valves.valve_c2(),
    # Primary pump to steam generator
    "A3" => API.Valves.valve_a3(),
    "B3" => API.Valves.valve_b3(),
    "C3" => API.Valves.valve_c3(),
    # Steam generator to turbine (MSCV)
    "A4" => API.Valves.valve_a4(),
    "B4" => API.Valves.valve_b4(),
    "C4" => API.Valves.valve_c4(),
    # Turbine to condenser
    "A5" => API.Valves.valve_a5(),
    "B5" => API.Valves.valve_b5(),
    "C5" => API.Valves.valve_c5(),
    # Condenser to secondary pump
    "A6" => API.Valves.valve_a6(),
    "B6" => API.Valves.valve_b6(),
    "C6" => API.Valves.valve_c6(),
    # Steam generator drain
    "DV01" => API.Valves.steam_gen_drain(1),
    "DV02" => API.Valves.steam_gen_drain(2),
    "DV03" => API.Valves.steam_gen_drain(3)
  }

  @other_valves %{
    # Other valves with actuators
    "PZR COOLING" => API.Valves.pzr_cooling(),
    "PZR VENT" => API.Valves.pzr_vent(),
    "RCV" => API.Valves.rcv(),
    "CST DRAIN" => API.Valves.cst_drain(),
    "TURBINE A VENT" => API.Valves.turbine_vent(1),
    "TURBINE B VENT" => API.Valves.turbine_vent(2),
    "TURBINE C VENT" => API.Valves.turbine_vent(3)
  }

  @valves Map.merge(@base_valves, @other_valves)

  @groups %{
    "A*" => 1..6 |> Enum.map(&"A#{&1}"),
    "B*" => 1..6 |> Enum.map(&"B#{&1}"),
    "C*" => 1..6 |> Enum.map(&"C#{&1}"),
    "DV*" => 1..3 |> Enum.map(&"DV0#{&1}")
  }

  @moduledoc """
  Opens and closes valves with electronic actuators.

  Usage: `mix auto_nuke.valve <open|close> <valves or groups>`

  Possible valves:

  - **Loop 1 valves:** A1 .. A6
  - **Loop 2 valves:** B1 .. B6
  - **Loop 3 valves:** C1 .. C6
  - **Steam gen drain valves:** DV01 .. DV03
  #{@other_valves |> Map.keys() |> Enum.map(&"- #{&1}") |> Enum.join("\n")}

  Possible valve groups:

  #{@groups |> Enum.map(fn {k, v} -> "- `#{k}` — #{v |> Enum.join(", ")}" end) |> Enum.join("\n")}
  """

  def run([action | names]) do
    names
    |> Enum.flat_map(&find_valves/1)
    |> Enum.uniq()
    |> then(fn v ->
      UI.init()
      actuate(v, action)
    end)
  end

  defp find_valves(name) do
    name =
      name
      |> String.replace(~r{[^a-zA-Z0-9*]+}, " ")
      |> String.upcase()

    cond do
      group = Map.get(@groups, name) -> group |> Enum.map(&Map.fetch!(@valves, &1))
      valve = Map.get(@valves, name) -> [valve]
      true -> Mix.raise("Unknown valve or group: #{name}")
    end
  end

  defp actuate(valves, "open"), do: UI.Valves.bulk_open(valves)
  defp actuate(valves, "close"), do: UI.Valves.bulk_close(valves)
end
