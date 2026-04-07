defmodule AutoNuke.TaskUI.Pumps do
  alias AutoNuke.API.Pumps, as: PumpAPI
  alias AutoNuke.API.Pumps.Pump
  alias AutoNuke.TaskUI, as: UI

  def start(%Pump{switch_key: key} = pump) when is_binary(key) do
    UI.set_wait(
      pump.name,
      "ON",
      fn -> PumpAPI.get_switch(pump) end,
      fn -> PumpAPI.set_switch(pump, true) end
    )
  end

  def start(%Pump{switch_key: nil} = pump) do
    # Operator has to turn this pump on manually.
    # However, we can't tell the difference between a pump that is off,
    # or a pump that is on but has a speed of zero.
    # We need to set it to at least speed 1 before we can detect a manual start.

    if pump.set_key do
      PumpAPI.set_speed(pump, PumpAPI.get_ordered_speed(pump) |> max(1))
    end

    UI.wait(
      pump.name,
      "ON",
      fn -> PumpAPI.get_active?(pump) end
    )
  end

  def stop(%Pump{switch_key: key} = pump) when is_binary(key) do
    UI.set_wait(
      pump.name,
      "OFF",
      fn -> !PumpAPI.get_switch(pump) end,
      fn -> PumpAPI.set_switch(pump, false) end
    )
  end

  def stop(%Pump{switch_key: nil} = pump) do
    # Operator has to turn this pump off manually.

    if pump.set_key, do: PumpAPI.set_speed(pump, 0)

    UI.wait(
      pump.name,
      "OFF",
      fn ->
        if PumpAPI.get_active?(pump) do
          IO.write(:stderr, "\a")
          false
        else
          true
        end
      end
    )
  end

  def set_speed(%Pump{} = pump, target, opts \\ []) do
    {wait?, opts} = Keyword.pop(opts, :wait, true)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    action =
      case target do
        0 -> "OFF (0%)"
        25 -> "LOW (25%)"
        50 -> "MEDIUM (50%)"
        100 -> "HIGH (100%)"
        _ -> "SET TO #{target}%"
      end

    UI.set_wait(
      pump.name,
      action,
      fn -> PumpAPI.get_ordered_speed(pump) == target end,
      fn -> PumpAPI.set_speed(pump, target) end
    )

    if wait? do
      initial = PumpAPI.get_actual_speed(pump)

      if initial != target do
        UI.ProgressBar.wait(
          config: UI.ProgressBar.Config.target(initial, target, "%"),
          label: pump.name,
          current_fn: fn -> PumpAPI.get_actual_speed(pump) end
        )
      end
    end
  end
end
