defmodule Mix.Tasks.AutoNuke.Refill.Truck.Cargo do
  @enforce_keys [:name, :aliases, :vessel, :valve]
  defstruct(@enforce_keys)
end

defmodule Mix.Tasks.AutoNuke.Refill.Truck do
  @moduledoc "Loads fuel or chemicals from a tanker truck"
  @shortdoc "Loads from a truck"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias Mix.Tasks.AutoNuke.Refill.Truck.Cargo

  @target_fill_percent 95
  @pump API.Pumps.transfer()

  @cargos [
    %Cargo{
      name: "Boric Acid",
      aliases: ["boron", "boric acid"],
      vessel: API.Vessels.boric_acid(),
      valve: API.Valves.boron_transfer()
    },
    %Cargo{
      name: "Sodium Hydroxide",
      aliases: ["sodium hydroxide", "NaOH", "lye"],
      vessel: API.Vessels.sodium_hydroxide(),
      valve: API.Valves.sodium_transfer()
    },
    %Cargo{
      name: "Diesel Fuel",
      aliases: ["fuel", "diesel fuel"],
      vessel: API.Vessels.diesel_fuel(),
      valve: API.Valves.fuel_transfer()
    }
  ]

  def run(args) do
    Enum.join(args, " ")
    |> find_cargo()
    |> refill()
  end

  defp find_cargo(name) do
    name_lower = String.downcase(name)

    case @cargos |> Enum.filter(&match_aliases(name_lower, &1.aliases)) do
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
    UI.init()

    check_valves(cargo)

    UI.Refill.refill(
      vessel: cargo.vessel,
      pump: @pump,
      target_level: @target_fill_percent
    )
  end

  defp check_valves(my_cargo) do
    @cargos
    |> Enum.each(fn
      ^my_cargo -> UI.Valves.open(my_cargo.valve)
      other_cargo -> UI.Valves.close(other_cargo.valve)
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
end
