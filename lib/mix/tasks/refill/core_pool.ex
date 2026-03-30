defmodule Mix.Tasks.AutoNuke.Refill.CorePool do
  @moduledoc "Refills or empties the core pool"
  @shortdoc "Refills or empties core pool"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @core_storage_tank_size 80_000
  # Start pumping once core pool storage is 25% full.
  @min_core_storage_start @core_storage_tank_size * 0.25
  # Stop pumping if it drops below 5% full.
  @min_core_storage_stop @core_storage_tank_size * 0.05

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

  def run([target]) do
    {target, ""} = Float.parse(target)
    fill_or_empty(target)
  end

  defp fill_or_empty(target) when target >= 0.0 and target <= 100.0 do
    {:ok, _} = Application.ensure_all_started([:req])

    if target < get_pool_fill_percent() do
      empty(target)
    else
      fill_loop(target)
    end
  end

  defp empty(target) do
    AutoNuke.Tasks.Refill.refill(
      pump_name: "Core Pool Pump",
      tank_description: "Pool Emptying",
      pump_get_active: fn -> get_pump_state() == 1 end,
      pump_set_enabled: fn
        true -> set_pump("REMOVE")
        false -> set_pump("OFF")
      end,
      tank_get_level: &get_pool_empty_percent/0,
      target_level: 100 - target
    )
  end

  defp fill_loop(target) do
    try do
      AutoNuke.Tasks.Refill.refill(
        pre_check: &check_core_storage_tank/0,
        pump_name: "Core Pool Pump",
        tank_description: "Pool Filling",
        pump_get_active: fn -> get_pump_state() == 3 end,
        pump_set_enabled: fn
          true -> set_pump("LOAD")
          false -> set_pump("OFF")
        end,
        tank_get_level: &fill_check_get_percent/0,
        target_level: target
      )
    catch
      :empty_tank -> :ok
    end

    if target > get_pool_fill_percent() do
      fill_loop(target)
    end
  end

  defp check_core_storage_tank do
    min = round(@min_core_storage_start / 1000)

    UI.wait(
      "Primary Core Storage Tank",
      "FILL TO #{min} kL",
      fn -> get_core_storage_fill() >= @min_core_storage_start end
    )
  end

  defp fill_check_get_percent do
    if get_core_storage_fill() < @min_core_storage_stop do
      throw(:empty_tank)
    else
      get_pool_fill_percent()
    end
  end

  defp get_core_storage_fill do
    API.get_float("CORE_POOL_COOLANT_TANK_VOLUME")
  end

  defp raw_fill_percent do
    API.get_json("VALVE_PANEL_JSON")
    |> Map.fetch!("vessels")
    |> Map.fetch!("CORE POOL")
    |> Map.fetch!("Volume")
    |> then(fn [current, max] -> current / max * 100 end)
  end

  defp get_pool_fill_percent, do: raw_fill_percent() |> Float.floor(1)
  defp get_pool_empty_percent, do: (100 - raw_fill_percent()) |> Float.ceil(1)

  defp get_pump_state, do: API.get_integer("CORE_POOL_PUMP")

  defp set_pump(mode) do
    API.put("CORE_POOL_PUMP", mode)
    Process.sleep(100)

    if get_pump_state() == mode_number(mode) do
      :ok
    else
      set_pump(mode)
    end
  end

  defp mode_number("REMOVE"), do: 1
  defp mode_number("OFF"), do: 2
  defp mode_number("LOAD"), do: 3
end
