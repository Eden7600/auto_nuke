defmodule AutoNuke.API.Pumps do
  alias AutoNuke.API

  defmodule Pump do
    @enforce_keys [:name]

    defstruct(
      name: nil,
      actual_key: nil,
      ordered_key: nil,
      set_key: nil,
      active_key: nil,
      switch_key: nil,
      capacity_key: nil,
      valve_panel_key: nil
    )
  end

  def primary(loop) when loop in 1..3,
    do: %Pump{
      name: "Circulation Pump 0#{loop}",
      actual_key: "COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_SPEED",
      ordered_key: "COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED",
      set_key: "COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED",
      # no switch key available :(
      capacity_key: "COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_CAPACITY",
      valve_panel_key: "BC_#{loop - 1}_REFRIGERANTE_CIRCULACION"
    }

  def all_primary, do: 1..3 |> Enum.map(&primary/1)

  def secondary(loop) when loop in 1..3,
    do: %Pump{
      name: "Secondary Pump 0#{loop}",
      actual_key: "COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_SPEED",
      ordered_key: "COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED",
      set_key: "COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED",
      # no switch key available :(
      capacity_key: "COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_CAPACITY",
      valve_panel_key: "BC_#{loop - 1}_GENERADOR_CIRCULACION"
    }

  def all_secondary, do: 1..3 |> Enum.map(&secondary/1)

  def condenser_cooling,
    do: %Pump{
      name: "Condenser Cooling Pump",
      # no capacity key available
      actual_key: "CONDENSER_CIRCULATION_PUMP_SPEED",
      ordered_key: "CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED",
      set_key: "CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED",
      switch_key: "CONDENSER_CIRCULATION_PUMP_SWITCH",
      valve_panel_key: "BC_0_CONDENSADOR_CIRCULACION"
    }

  def condenser_freight,
    do: %Pump{
      name: "Secondary Circuit Freight Pump",
      active_key: "FREIGHT_PUMP_CONDENSER_ACTIVE",
      switch_key: "FREIGHT_PUMP_CONDENSER_SWITCH",
      valve_panel_key: "BC_1_CONDENSADOR_CARGA"
    }

  def external_freight,
    do: %Pump{
      name: "External Freight Pump",
      active_key: "FREIGHT_PUMP_EXTERNAL_ACTIVE",
      switch_key: "FREIGHT_PUMP_EXTERNAL_SWITCH",
      valve_panel_key: "BC_0_EXTERIOR_CARGA"
    }

  def internal_freight,
    do: %Pump{
      name: "Internal Freight Pump",
      active_key: "FREIGHT_PUMP_INTERNAL_ACTIVE",
      switch_key: "FREIGHT_PUMP_INTERNAL_SWITCH",
      valve_panel_key: "BC_1_EXTERIOR_CARGA"
    }

  def primary_circuit,
    do: %Pump{
      name: "Primary Circuit Pump",
      active_key: "FREIGHT_PUMP_FEEDWATER_ACTIVE",
      switch_key: "FREIGHT_PUMP_FEEDWATER_SWITCH",
      valve_panel_key: "BC_0_REFRIGERANTE_CARGA"
    }

  def core_pool,
    do: %Pump{
      name: "Core Pool Pump",
      valve_panel_key: "BC_2_NUCLEO_CARGA"
    }

  def transfer,
    do: %Pump{
      name: "Transfer Freight Pump",
      valve_panel_key: "BC_2_EXTERIOR_CARGA"
    }

  def boron_dosing,
    do: %Pump{
      name: "Boron Dosing Pump",
      actual_key: "CHEM_BORON_DOSAGE_ACTUAL",
      ordered_key: "CHEM_BORON_DOSAGE_ORDERED",
      set_key: "CHEM_BORON_DOSAGE_ORDERED_RATE",
      valve_panel_key: "BC_0_QUIMICA_DOSIFICADORA"
    }

  def boron_filter,
    do: %Pump{
      name: "Ion Exchange Pump",
      actual_key: "CHEM_BORON_FILTER_ACTUAL",
      ordered_key: "CHEM_BORON_FILTER_ORDERED",
      set_key: "CHEM_BORON_FILTER_ORDERED_SPEED",
      valve_panel_key: "BC_0_QUIMICA_CIRCULACION_QUIMICA"
    }

  def chemical_cleaning,
    do: %Pump{
      name: "Chemical Cleaning Pump",
      valve_panel_key: "BC_1_QUIMICA_CIRCULACION_QUIMICA"
    }

  def get_ordered_speed(%Pump{ordered_key: k}) when is_binary(k), do: API.get_integer(k)

  def get_ordered_speed(%Pump{ordered_key: nil, name: n}),
    do: raise("Can't read #{n} ordered speed")

  def get_actual_speed(%Pump{actual_key: k}) when is_binary(k), do: API.get_float(k)
  def get_actual_speed(%Pump{actual_key: nil, name: n}), do: raise("Can't read #{n} actual speed")

  def set_speed(%Pump{set_key: k}, v) when is_binary(k), do: API.put(k, v)
  def set_speed(%Pump{set_key: nil, name: n}), do: raise("Can't set #{n} speed")

  def get_capacity(%Pump{capacity_key: k}) when is_binary(k), do: API.get_integer(k)
  def get_capacity(%Pump{capacity_key: nil, name: n}), do: raise("Can't read #{n} capacity")

  def get_switch(%Pump{switch_key: k}) when is_binary(k), do: API.get_boolean(k)
  def get_switch(%Pump{switch_key: nil, name: n}), do: raise("Can't get #{n} switch")

  def set_switch(%Pump{switch_key: k}, v) when is_binary(k), do: API.put(k, v)
  def set_switch(%Pump{switch_key: nil, name: n}), do: raise("Can't set #{n} switch")

  def get_active?(%Pump{active_key: k}) when is_binary(k), do: API.get_boolean(k)

  def get_active?(%Pump{actual_key: k}) when is_binary(k), do: API.get_float(k) > 0

  def get_active?(%Pump{valve_panel_key: k}) when is_binary(k) do
    valve_panel(k)
    |> Map.fetch!("State")
    |> Map.fetch!("Active")
  end

  def installed?(%Pump{valve_panel_key: k}) when is_binary(k) do
    valve_panel()
    |> Map.has_key?(k)
  end

  defp valve_panel, do: AutoNuke.API.get_json("VALVE_PANEL_JSON") |> Map.fetch!("pumps")
  defp valve_panel(key) when is_binary(key), do: valve_panel() |> Map.fetch!(key)
end
