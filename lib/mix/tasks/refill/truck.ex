defmodule Mix.Tasks.AutoNuke.Refill.Truck do
  @moduledoc "Loads fuel or chemicals from a tanker truck"
  @shortdoc "Loads from a truck"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @target_fill_percent 95

  defmodule Cargo do
    @enforce_keys [:name, :aliases, :tank_key, :valve_key]
    defstruct(@enforce_keys)
  end

  def cargos do
    [
      %Cargo{
        name: "Boric Acid",
        aliases: ["boron", "boric acid"],
        tank_key: "BORIC ACID",
        valve_key: "Camion_Valve_01_Boro"
      },
      %Cargo{
        name: "Sodium Hydroxide",
        aliases: ["sodium hydroxide", "NaOH", "lye"],
        tank_key: "SODIUM HYDROXIDE",
        valve_key: "Camion_Valve_02_NaOH"
      },
      %Cargo{
        name: "Diesel Fuel",
        aliases: ["fuel", "diesel fuel"],
        tank_key: "DIESEL FUEL",
        valve_key: "Camion_Valve_03_Fuel"
      }
    ]
  end

  def run(args) do
    Enum.join(args, " ")
    |> find_cargo()
    |> refill()
  end

  defp find_cargo(name) do
    name_lower = String.downcase(name)

    case cargos() |> Enum.filter(&match_aliases(name_lower, &1.aliases)) do
      [match] -> match
      [] -> raise "No cargo matching #{inspect(name)}"
      [_ | _] -> raise "Multiple matches, this shouldn't happen"
    end
  end

  defp match_aliases(name, aliases) do
    aliases
    |> Enum.any?(fn ali ->
      ali
      |> String.downcase()
      |> String.starts_with?(name)
    end)
  end

  defp refill(%Cargo{} = cargo) do
    AutoNuke.Tasks.Refill.refill(
      pre_check: fn -> pre_check(cargo) end,
      pump_name: "Transfer Pump",
      tank_description: cargo.name,
      pump_get_active: fn -> get_pump_active(cargo.tank_key) end,
      pump_set_enabled: fn _ -> :noop end,
      tank_get_level: fn -> get_tank_percent(cargo.tank_key) |> Float.round(1) end,
      target_level: @target_fill_percent
    )
  end

  defp pre_check(my_cargo) do
    cargos()
    |> Enum.each(fn
      ^my_cargo -> check_valve(my_cargo, true)
      other_cargo -> check_valve(other_cargo, false)
    end)

    UI.wait(
      "Tanker Truck",
      "IN ZONE",
      fn -> API.get_boolean("CHEM_TRUCK_IN_ZONE") end
    )

    UI.wait(
      "Tanker Truck",
      "CONNECTED",
      fn -> API.get_boolean("CHEM_TRUCK_CONNECTED") end
    )
  end

  defp check_valve(%Cargo{name: name, valve_key: key}, open) do
    verb = if open, do: "OPEN", else: "CLOSE"

    UI.wait(
      "#{name} Transfer Valve",
      verb,
      fn ->
        API.get_json("VALVE_PANEL_JSON")
        |> Map.fetch!("valves")
        |> Map.fetch!(key)
        |> Map.fetch!("State")
        |> Map.fetch!("IsOpened")
        |> Kernel.==(open)
      end
    )
  end

  defp get_tank_percent(key, json \\ nil) do
    (json || API.get_json("VALVE_PANEL_JSON"))
    |> Map.fetch!("vessels")
    |> Map.fetch!(key)
    |> Map.fetch!("Volume")
    |> then(fn [current, max] -> current / max * 100 end)
  end

  @pump_key "BC_2_EXTERIOR_CARGA"
  defp get_pump_active(tank_key) do
    json = API.get_json("VALVE_PANEL_JSON")

    json
    |> Map.fetch!("pumps")
    |> Map.fetch!(@pump_key)
    |> Map.fetch!("State")
    |> Map.fetch!("Active")
    |> then(fn active ->
      if active && get_tank_percent(tank_key, json) > @target_fill_percent do
        IO.binwrite(:stderr, "\a")
      end

      active
    end)
  end
end
