defmodule AutoNuke.API.Valves do
  alias AutoNuke.API
  alias AutoNuke.API.Valves.{ActuatedValve, OrderedValve}

  defmodule ActuatedValve do
    @enforce_keys [:name, :short_name, :valve_panel_key]
    defstruct(@enforce_keys)
  end

  defmodule OrderedValve do
    @enforce_keys [:name, :short_name, :actual_key, :set_key]
    defstruct(
      name: nil,
      short_name: nil,
      ordered_key: nil,
      actual_key: nil,
      set_key: nil
    )
  end

  defmodule ManualValve do
    @enforce_keys [:name, :short_name, :valve_panel_key]
    defstruct(
      name: nil,
      short_name: nil,
      get_key: nil,
      valve_panel_key: nil
    )
  end

  defp loop_letter(1), do: "A"
  defp loop_letter(2), do: "B"
  defp loop_letter(3), do: "C"

  def mscv(loop) when loop in 1..3,
    do: %OrderedValve{
      name: "Main Steam Control Valve 0#{loop}",
      short_name: "MSCV 0#{loop}",
      actual_key: "MSCV_#{loop - 1}_OPENING_ACTUAL",
      set_key: "MSCV_#{loop - 1}_OPENING_ORDERED"
    }

  def turbine_bypass(loop) when loop in 1..3,
    do: %OrderedValve{
      name: "Turbine Bypass 0#{loop}",
      short_name: "Bypass 0#{loop}",
      actual_key: "STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL",
      set_key: "STEAM_TURBINE_#{loop - 1}_BYPASS_ORDERED"
    }

  def turbine_vent(loop) when loop in 1..3,
    do: %ActuatedValve{
      name: "Turbine #{loop_letter(loop)} Vent Valve",
      short_name: "Vent #{loop_letter(loop)}",
      valve_panel_key: "VALVULA_VENT_TURBINA_0#{loop}"
    }

  # Condenser valves:
  def smsi,
    do: %OrderedValve{
      name: "Startup Motive Steam Inlet",
      short_name: "SMSI",
      ordered_key: "STEAM_EJECTOR_STARTUP_MOTIVE_VALVE_ORDERED",
      actual_key: "STEAM_EJECTOR_STARTUP_MOTIVE_VALVE_ACTUAL",
      set_key: "STEAM_EJECTOR_STARTUP_MOTIVE_VALVE"
    }

  def omsi,
    do: %OrderedValve{
      name: "Operational Motive Steam Inlet",
      short_name: "OMSI",
      ordered_key: "STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE_ORDERED",
      actual_key: "STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE_ACTUAL",
      set_key: "STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE"
    }

  def crv,
    do: %OrderedValve{
      name: "Condensate Return Valve",
      short_name: "CRV",
      ordered_key: "STEAM_EJECTOR_CONDENSER_RETURN_VALVE_ORDERED",
      actual_key: "STEAM_EJECTOR_CONDENSER_RETURN_VALVE_ACTUAL",
      set_key: "STEAM_EJECTOR_CONDENSER_RETURN_VALVE"
    }

  # Core to primary pump
  def valve_a1,
    do: %ActuatedValve{
      name: "Valve A1",
      short_name: "A1",
      valve_panel_key: "VALVULA_ENTRADA_NUCLEO_01"
    }

  def valve_b1,
    do: %ActuatedValve{
      name: "Valve B1",
      short_name: "B1",
      valve_panel_key: "VALVULA_ENTRADA_NUCLEO_02"
    }

  def valve_c1,
    do: %ActuatedValve{
      name: "Valve C1",
      short_name: "C1",
      valve_panel_key: "VALVULA_ENTRADA_NUCLEO_03"
    }

  # Steam generator return to core
  def valve_a2,
    do: %ActuatedValve{
      name: "Valve A2",
      short_name: "A2",
      valve_panel_key: "VALVULA_SALIDA_NUCLEO_01"
    }

  def valve_b2,
    do: %ActuatedValve{
      name: "Valve B2",
      short_name: "B2",
      valve_panel_key: "VALVULA_SALIDA_NUCLEO_02"
    }

  def valve_c2,
    do: %ActuatedValve{
      name: "Valve C2",
      short_name: "C2",
      valve_panel_key: "VALVULA_SALIDA_NUCLEO_03"
    }

  # Primary pump to steam generator
  def valve_a3,
    do: %ActuatedValve{
      name: "Valve A3",
      short_name: "A3",
      valve_panel_key: "VALVULA_ENTRE_BC_Y_EVA_01"
    }

  def valve_b3,
    do: %ActuatedValve{
      name: "Valve B3",
      short_name: "B3",
      valve_panel_key: "VALVULA_ENTRE_BC_Y_EVA_02"
    }

  def valve_c3,
    do: %ActuatedValve{
      name: "Valve C3",
      short_name: "C3",
      valve_panel_key: "VALVULA_ENTRE_BC_Y_EVA_03"
    }

  # Steam generator to turbine (MSCV)
  def valve_a4,
    do: %ActuatedValve{
      name: "Valve A4",
      short_name: "A4",
      valve_panel_key: "VALVULA_ENTRADA_TURBINA_01"
    }

  def valve_b4,
    do: %ActuatedValve{
      name: "Valve B4",
      short_name: "B4",
      valve_panel_key: "VALVULA_ENTRADA_TURBINA_02"
    }

  def valve_c4,
    do: %ActuatedValve{
      name: "Valve C4",
      short_name: "C4",
      valve_panel_key: "VALVULA_ENTRADA_TURBINA_03"
    }

  # Turbine to condenser
  def valve_a5,
    do: %ActuatedValve{
      name: "Valve A5",
      short_name: "A5",
      valve_panel_key: "VALVULA_ENTRADA_CONDENSADOR_01"
    }

  def valve_b5,
    do: %ActuatedValve{
      name: "Valve B5",
      short_name: "B5",
      valve_panel_key: "VALVULA_ENTRADA_CONDENSADOR_02"
    }

  def valve_c5,
    do: %ActuatedValve{
      name: "Valve C5",
      short_name: "C5",
      valve_panel_key: "VALVULA_ENTRADA_CONDENSADOR_03"
    }

  # Condenser to secondary pump
  def valve_a6,
    do: %ActuatedValve{
      name: "Valve A6",
      short_name: "A6",
      valve_panel_key: "VALVULA_SALIDA_CONDENSADOR_01"
    }

  def valve_b6,
    do: %ActuatedValve{
      name: "Valve B6",
      short_name: "B6",
      valve_panel_key: "VALVULA_SALIDA_CONDENSADOR_02"
    }

  def valve_c6,
    do: %ActuatedValve{
      name: "Valve C6",
      short_name: "C6",
      valve_panel_key: "VALVULA_SALIDA_CONDENSADOR_03"
    }

  def pzr_cooling,
    do: %ActuatedValve{
      name: "Pressurizer Cooling Valve",
      short_name: "PZR Cooling",
      valve_panel_key: "Valvula_Pressurizer_Spray"
    }

  def pzr_vent,
    do: %ActuatedValve{
      name: "Pressurizer Vent Valve",
      short_name: "PZR Vent",
      valve_panel_key: "Valvula_Pressurizer_Vent"
    }

  def rcv,
    do: %ActuatedValve{
      name: "Release Coolant Valve",
      short_name: "RCV",
      valve_panel_key: "Valvula_Descargar_REF"
    }

  def cst_drain,
    do: %ActuatedValve{
      name: "Coolant Storage Tank Drain Valve",
      short_name: "CST Drain",
      valve_panel_key: "Valvula_Purgar_Coolant"
    }

  def condenser_drain,
    do: %ActuatedValve{
      name: "Condenser Drain Valve",
      short_name: "Condenser Drain",
      valve_panel_key: "VALVULA_PURGA_C2_01"
    }

  def ion_inlet,
    do: %ManualValve{
      name: "Ion Filter Inlet Valve",
      short_name: "Ion Inlet",
      valve_panel_key: "Core_Valve_01"
    }

  def ion_outlet,
    do: %ManualValve{
      name: "Ion Filter Outlet Valve",
      short_name: "Ion Outlet",
      valve_panel_key: "Core_Valve_02"
    }

  def valve_m01,
    do: %ManualValve{
      name: "Valve M01",
      short_name: "M01",
      get_key: "VALVE_M01_OPEN",
      valve_panel_key: "Valve_Q_TANQUE_AGUA"
    }

  def valve_m02,
    do: %ManualValve{
      name: "Valve M02",
      short_name: "M02",
      get_key: "VALVE_M02_OPEN",
      valve_panel_key: "Valve_Q_TANQUE_AGUA_CORE_EXTERNO"
    }

  def valve_m03,
    do: %ManualValve{
      name: "Valve M03",
      short_name: "M03",
      get_key: "VALVE_M03_OPEN",
      valve_panel_key: "Valve_Q_TANQUE_AGUA_MAIN"
    }

  def boron_transfer,
    do: %ManualValve{
      name: "Boric Acid Transfer Valve",
      short_name: "Boron Transfer",
      valve_panel_key: "Camion_Valve_01_Boro"
    }

  def sodium_transfer,
    do: %ManualValve{
      name: "Sodium Hydroxide Transfer Valve",
      short_name: "NaOH Transfer",
      valve_panel_key: "Camion_Valve_02_NaOH"
    }

  def fuel_transfer,
    do: %ManualValve{
      name: "Diesel Fuel Transfer Valve",
      short_name: "Fuel Transfer",
      valve_panel_key: "Camion_Valve_03_Fuel"
    }

  @actuator_settings ["OPEN", "OFF", "CLOSE"]

  defp valve_panel(key) when is_binary(key) do
    AutoNuke.API.get_json("VALVE_PANEL_JSON")
    |> Map.fetch!("valves")
    |> Map.fetch!(key)
  end

  def get_open_percent(%ActuatedValve{valve_panel_key: k}),
    do: valve_panel(k) |> Map.fetch!("Value")

  def get_open_percent(%OrderedValve{actual_key: k}), do: API.get_float(k)

  def get_ordered_open_percent(%OrderedValve{ordered_key: k}) when is_binary(k),
    do: API.get_float(k)

  def get_closed_percent(term), do: 100 - get_open_percent(term)

  def set_open_percent(%OrderedValve{set_key: k}, v), do: API.put(k, v)

  def get_actuator(%ActuatedValve{valve_panel_key: k}),
    do: valve_panel(k) |> Map.fetch!("Actuator")

  def set_actuator(%ActuatedValve{valve_panel_key: key}, action)
      when action in @actuator_settings do
    AutoNuke.API.put("VALVE_#{action}", key)
  end

  def get_opened?(%ManualValve{get_key: k}) when is_binary(k), do: API.get_float(k) == 100

  def get_opened?(%ManualValve{valve_panel_key: k}) do
    valve_panel(k)
    |> Map.fetch!("State")
    |> Map.fetch!("IsOpened")
  end

  def get_opened?(%t{} = v) when t in [OrderedValve, ActuatedValve], do: get_open_percent(v) > 0
end
