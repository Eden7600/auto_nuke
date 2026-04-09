defmodule Mix.Tasks.AutoNuke.Refill.CorePool do
  @moduledoc "Refills or empties the core pool"
  @shortdoc "Refills or empties core pool"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.TaskUI.ProgressBar.Config, as: PBConfig

  @core_pool API.Vessels.core_pool()
  @storage_tank API.Vessels.core_pool_storage()
  # Start pumping once core pool storage is 25% full.
  @min_core_storage_start @storage_tank.capacity * 0.25
  # Stop pumping if it drops below 5% full.
  @min_core_storage_stop @storage_tank.capacity * 0.05

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
    UI.init()

    if target < API.Vessels.get_fill_percent(@core_pool) do
      empty(target)
    else
      fill_loop(target)
    end
  end

  defp empty(target) do
    UI.wait(
      "Core Pool Pump",
      "REMOVE",
      fn -> set_pump("REMOVE") end
    )

    try do
      UI.ProgressBar.wait(
        config: %PBConfig{PBConfig.reverse_percent() | right: target},
        label: @core_pool.short_name,
        current_fn: fn -> API.Vessels.get_fill_percent(@core_pool) end,
        done_fn: &(&1 <= target)
      )
    after
      UI.wait(
        "Core Pool Pump",
        "OFF",
        fn -> set_pump("OFF") end
      )
    end
  end

  defp fill_loop(target) do
    check_core_storage_tank()

    try do
      UI.wait(
        "Core Pool Pump",
        "LOAD",
        fn -> set_pump("LOAD") end
      )

      UI.ProgressBar.wait(
        config: %PBConfig{PBConfig.percent() | right: target},
        label: @core_pool.short_name,
        current_fn: fn -> API.Vessels.get_fill_percent(@core_pool) end,
        done_fn: &fill_check(&1, target)
      )
    catch
      :empty_tank -> :ok
    after
      UI.wait(
        "Core Pool Pump",
        "OFF",
        fn -> set_pump("OFF") end
      )
    end

    if target > API.Vessels.get_fill_percent(@core_pool) do
      fill_loop(target)
    end
  end

  defp check_core_storage_tank do
    min = round(@min_core_storage_start / 1000)

    if get_pump_state() != mode_number("OFF") do
      UI.wait(
        "Core Pool Pump",
        "OFF",
        fn -> set_pump("OFF") end
      )
    end

    UI.wait(
      "Primary Core Storage Tank",
      "FILL TO #{min} kL",
      fn -> get_core_storage_fill() >= @min_core_storage_start end
    )
  end

  defp fill_check(percent, target) do
    if get_core_storage_fill() < @min_core_storage_stop do
      true
    else
      percent >= target
    end
  end

  defp get_core_storage_fill, do: @storage_tank |> API.Vessels.get_fill_volume()
  defp get_pump_state, do: API.get_integer("CORE_POOL_PUMP")

  defp set_pump(mode) do
    if get_pump_state() == mode_number(mode) do
      true
    else
      API.put("CORE_POOL_PUMP", mode)
      false
    end
  end

  defp mode_number("REMOVE"), do: 1
  defp mode_number("OFF"), do: 2
  defp mode_number("LOAD"), do: 3
end
