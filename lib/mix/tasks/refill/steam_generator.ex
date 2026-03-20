defmodule Mix.Tasks.AutoNuke.Refill.Secondary do
  @moduledoc "Refills specified steam generator to specified gauge level"
  @shortdoc "Refills steam generator"

  use Mix.Task
  alias AutoNuke.API

  @tank_size 600_000
  @gauge_factor 100
  @max div(@tank_size, @gauge_factor)

  def run([loop, target]) do
    target = target |> String.to_integer()
    loop = parse_loop(loop)

    refill(loop, target)
  end

  def refill(loop, target) when target >= 0 and target <= @max do
    AutoNuke.Tasks.Refill.refill(
      pump_name: "L#{loop} Secondary Pump",
      tank_description: "L#{loop} Coolant Volume",
      pump_get_active: fn -> is_pump_active?(loop) end,
      pump_set_enabled: &set_pump_enabled(loop, &1),
      tank_get_level: fn -> get_loop_volume(loop, target) end,
      target_level: target
    )
  end

  defp is_pump_active?(loop), do: get_speed(loop) >= 1
  defp set_pump_enabled(loop, true), do: set_speed(loop, 1)
  defp set_pump_enabled(loop, false), do: set_speed(loop, 0)

  defp get_speed(loop) do
    API.get_float("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_SPEED")
  end

  defp set_speed(loop, value) do
    API.put("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", value)
  end

  defp get_loop_volume(loop, target) do
    volume =
      API.get_float("COOLANT_SEC_#{loop - 1}_LIQUID_VOLUME")
      |> floor()
      |> div(@gauge_factor)

    pump_speed =
      (target - volume)
      |> Kernel./(5)
      |> ceil()
      |> min(100)

    set_speed(loop, pump_speed)
    volume
  end

  defp parse_loop("1"), do: 1
  defp parse_loop("A"), do: 1
  defp parse_loop("a"), do: 1

  defp parse_loop("2"), do: 2
  defp parse_loop("B"), do: 2
  defp parse_loop("b"), do: 2

  defp parse_loop("3"), do: 3
  defp parse_loop("C"), do: 3
  defp parse_loop("c"), do: 3
end
