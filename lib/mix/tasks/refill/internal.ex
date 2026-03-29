defmodule Mix.Tasks.AutoNuke.Refill.Internal do
  @moduledoc "Refills multiple tanks with the Internal Freight Pump"
  @shortdoc "Refills M01/M02/M03"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  defmodule Tank do
    @enforce_keys [:name, :key, :valve, :valve_key]
    defstruct(
      name: nil,
      key: nil,
      valve: nil,
      valve_key: nil,
      open?: nil,
      fill_level: nil,
      capacity: nil
    )
  end

  @target_percent 100

  def tanks do
    [
      %Tank{
        name: "Rinse Tank",
        key: "RINSE TANK",
        valve: "M01",
        valve_key: "Valve_Q_TANQUE_AGUA"
      },
      %Tank{
        name: "Primary Circuit Storage Tank",
        key: "PRIMARY CIRCUIT STORAGE TANK",
        valve: "M02",
        valve_key: "Valve_Q_TANQUE_AGUA_MAIN"
      },
      %Tank{
        name: "Core Pool Storage Tank",
        key: "CORE POOL STORAGE TANK",
        valve: "M03",
        valve_key: "Valve_Q_TANQUE_AGUA_CORE_EXTERNO"
      }
    ]
  end

  def run([]) do
    AutoNuke.Tasks.Refill.refill(
      pre_check: &check_valves/0,
      pump_name: "Internal Freight Pump",
      tank_description: "All Tanks",
      pump_get_active: &is_pump_active?/0,
      pump_set_enabled: &set_pump_enabled/1,
      tank_get_level: &get_percent_full/0,
      target_level: @target_percent
    )
  end

  defp check_valves do
    tanks_status()
    |> Enum.map(fn tank ->
      case tank.open? do
        true -> UI.wait("Valve #{tank.valve}", "IS OPEN", fn -> true end)
        false -> UI.set("Valve #{tank.valve}", "IS CLOSED")
      end

      tank.open?
    end)
    |> then(fn open ->
      unless Enum.any?(open) do
        raise "No tanks open, can't start pump"
      end
    end)

    UI.notice("You can safely open and close valves while this task is running.")
  end

  @switch "FREIGHT_PUMP_INTERNAL_SWITCH"
  @active "FREIGHT_PUMP_INTERNAL_ACTIVE"
  defp is_pump_active?, do: API.get_boolean(@active)
  defp set_pump_enabled(true), do: API.put(@switch, "True")
  defp set_pump_enabled(false), do: API.put(@switch, "False")

  defp get_percent_full do
    tanks_status()
    |> Enum.filter(fn tank -> tank.open? end)
    |> then(fn
      [] ->
        100.0

      tanks ->
        tanks
        |> Enum.map(fn tank -> tank.fill_level / tank.capacity * 100 end)
        |> Statistex.average()
    end)
    |> Float.ceil(1)
  end

  defp tanks_status do
    %{"valves" => valves, "vessels" => vessels} = API.get_json("VALVE_PANEL_JSON")

    tanks()
    |> Enum.map(fn %Tank{} = tank ->
      vessel = Map.fetch!(vessels, tank.key)
      valve = Map.fetch!(valves, tank.valve_key)
      open = Map.fetch!(valve, "State") |> Map.fetch!("IsOpened")
      [fill_level, capacity] = Map.fetch!(vessel, "Volume")

      %Tank{tank | open?: open, fill_level: fill_level, capacity: capacity}
    end)
  end
end
