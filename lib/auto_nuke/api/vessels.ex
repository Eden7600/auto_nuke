defmodule AutoNuke.API.Vessels do
  alias AutoNuke.API
  alias AutoNuke.API.Vessels.Vessel

  defmodule Vessel do
    @enforce_keys [:name, :short_name, :capacity]
    defstruct(
      name: nil,
      short_name: nil,
      capacity: nil,
      units: "L",
      gauge_units: nil,
      volume_key: nil,
      vapour_volume_key: nil,
      total_volume_key: nil,
      fill_level_key: nil,
      temperature_key: nil,
      pressure_key: nil,
      valve_panel_key: nil
    )
  end

  def steam_generator(loop) when loop in 1..3,
    do: %Vessel{
      name: "Steam Generator 0#{loop}",
      short_name: "Steam Gen #{loop}",
      capacity: 60_000,
      gauge_units: "hL",
      volume_key: "COOLANT_SEC_#{loop - 1}_LIQUID_VOLUME",
      total_volume_key: "COOLANT_SEC_#{loop - 1}_VOLUME",
      temperature_key: "COOLANT_SEC_#{loop - 1}_TEMPERATURE",
      pressure_key: "COOLANT_SEC_#{loop - 1}_PRESSURE",
      valve_panel_key: "SteamGenerators_#{loop}"
    }

  def emergency_generator(num) when num in 1..2,
    do: %Vessel{
      name: "Emergency Generator #{num} Fuel Tank",
      short_name: "Generator #{num} Fuel",
      capacity: 500,
      gauge_units: "L",
      volume_key: "EMERGENCY_GENERATOR_#{num}_FUEL"
    }

  def core_vessel,
    do: %Vessel{
      name: "Core Coolant Primary Loop",
      short_name: "Core",
      capacity: 120_000,
      gauge_units: "m³",
      volume_key: "COOLANT_CORE_QUANTITY_IN_VESSEL",
      fill_level_key: "COOLANT_CORE_PRIMARY_LOOP_LEVEL",
      temperature_key: "CORE_TEMP",
      pressure_key: "CORE_PRESSURE"
    }

  def pressurizer,
    do: %Vessel{
      name: "Pressurizer",
      short_name: "Pressurizer",
      capacity: 1200,
      valve_panel_key: "PRESSURIZER"
    }

  def condenser,
    do: %Vessel{
      name: "Condenser",
      short_name: "Condenser",
      capacity: 360_000,
      gauge_units: "hL",
      temperature_key: "CONDENSER_TEMPERATURE",
      volume_key: "CONDENSER_VOLUME",
      vapour_volume_key: "CONDENSER_VAPOR_VOLUME",
      pressure_key: "CONDENSER_PRESSURE",
      valve_panel_key: "CONDENSER"
    }

  def retention_tank,
    do: %Vessel{
      name: "Condenser Retention Tank",
      short_name: "Retention Tank",
      capacity: 40_000,
      gauge_units: "%",
      volume_key: "VACUUM_RETENTION_TANK_VOLUME",
      pressure_key: "VACUUM_RETENTION_TANK_PRESSURE",
      valve_panel_key: "Condenser Retention Tank"
    }

  def core_pool,
    do: %Vessel{
      name: "Core Pool",
      short_name: "Core Pool",
      capacity: 150_000,
      gauge_units: "%",
      valve_panel_key: "CORE POOL"
    }

  def core_pool_storage,
    do: %Vessel{
      name: "Core Pool Storage Tank",
      short_name: "Core Pool Storage",
      capacity: 80_000,
      gauge_units: "kL",
      volume_key: "CORE_POOL_COOLANT_TANK_VOLUME",
      valve_panel_key: "CORE POOL STORAGE TANK"
    }

  def primary_cst,
    do: %Vessel{
      name: "Primary Circuit Storage Tank",
      short_name: "Primary CST",
      capacity: 150_000,
      gauge_units: "kL",
      volume_key: "CORE_PRIMARY_CIRCUIT_COOLING_TANK_VOLUME",
      valve_panel_key: "PRIMARY CIRCUIT STORAGE TANK"
    }

  def reservoir,
    do: %Vessel{
      name: "External Coolant Reservoir",
      short_name: "Reservoir",
      capacity: 500_000,
      gauge_units: "kL",
      volume_key: "CORE_EXTERNAL_COOLANT_RESERVOIR_VOLUME",
      valve_panel_key: "EXTERNAL RESERVOIR"
    }

  def boric_acid,
    do: %Vessel{
      name: "Boric Acid Tank",
      short_name: "Boric Acid",
      capacity: 100_000,
      gauge_units: "%",
      valve_panel_key: "BORIC ACID"
    }

  def sodium_hydroxide,
    do: %Vessel{
      name: "Sodium Hydroxide Tank",
      short_name: "NaOH",
      capacity: 100_000,
      gauge_units: "%",
      valve_panel_key: "SODIUM HYDROXIDE"
    }

  def diesel_fuel,
    do: %Vessel{
      name: "Diesel Fuel Tank",
      short_name: "Diesel",
      capacity: 4000,
      gauge_units: "%",
      valve_panel_key: "DIESEL FUEL"
    }

  def rinse_tank,
    do: %Vessel{
      name: "Rinse Tank",
      short_name: "Rinse",
      capacity: 80000,
      gauge_units: "%",
      valve_panel_key: "RINSE TANK"
    }

  def waste_tank,
    do: %Vessel{
      name: "Chemical Waste Tank",
      short_name: "Waste",
      capacity: 200_000,
      gauge_units: "%",
      # Not to be confused with "WASTE TANK" which seems to be something else.
      valve_panel_key: "CHEMICAL WASTE CONTAINER"
    }

  def get_fill_volume(v), do: get_volume_and_capacity(v) |> elem(0)

  def get_fill_percent(v), do: get_fill_ratio(v) * 100

  def get_fill_ratio(v) do
    {fill, max} = get_volume_and_capacity(v)
    fill / max
  end

  defp gauge_factor("kL"), do: 1000
  defp gauge_factor("hL"), do: 100
  defp gauge_factor("m³"), do: 48

  def get_fill_gauge(%Vessel{gauge_units: "%"} = v), do: get_fill_percent(v)
  def get_fill_gauge(%Vessel{gauge_units: u} = v), do: get_fill_volume(v) / gauge_factor(u)

  def get_temperature(%Vessel{temperature_key: k}) when is_binary(k), do: API.get_float(k)

  def get_temperature(%Vessel{valve_panel_key: k}) when is_binary(k),
    do: valve_panel(k) |> Map.fetch!("Temperature")

  def get_pressure(%Vessel{pressure_key: k}) when is_binary(k), do: API.get_float(k)

  def get_pressure(%Vessel{valve_panel_key: k}) when is_binary(k),
    do: valve_panel(k) |> Map.fetch!("Pressure")

  def gauge_to_ratio(%Vessel{gauge_units: "%"}, v), do: v / 100
  def gauge_to_ratio(%Vessel{capacity: c, gauge_units: u}, v), do: v * gauge_factor(u) / c

  defp get_volume_and_capacity(%Vessel{volume_key: k, capacity: c}) when is_binary(k),
    do: {API.get_float(k), c}

  defp get_volume_and_capacity(%Vessel{valve_panel_key: k}) when is_binary(k) do
    valve_panel(k)
    |> Map.fetch!("Volume")
    # We could use Vessel.capacity here, but eh, the data's right there.
    |> then(fn [current, max] -> {current, max} end)
  end

  defp valve_panel(key) do
    API.get_json("VALVE_PANEL_JSON")
    |> Map.fetch!("vessels")
    |> Map.fetch!(key)
  end
end
