defmodule AutoNuke.Operator.SecondaryFillTest do
  use ExUnit.Case, async: false

  alias AutoNuke.LoopIntent
  alias AutoNuke.Operator.SecondaryFill
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(SecondaryFill)

  setup do
    start_supervised!(PubSub)
    start_supervised!(LoopIntent)
    :ok
  end

  defp init(loop) do
    installed =
      for l <- 1..3, into: %{} do
        {"Loop_#{l - 1}",
         %{
           "Primary_Pump" => true,
           "Secondary_Pump" => true,
           "Steam_Generator" => true,
           "Turbine" => true
         }}
      end

    MockAPI.mock_get("INSTALLED_LOOPS_JSON", Jason.encode!(installed))
    MockAPI.mock_get("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_CAPACITY", 3000)
    MockAPI.mock_get("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", 20)
    MockAPI.mock_get("COOLANT_SEC_#{loop - 1}_LIQUID_VOLUME", 30_000.0)
    MockAPI.mock_get("COOLANT_SEC_#{loop - 1}_VOLUME", 60_000.0)

    {:ok, state} = SecondaryFill.init(loop)
    state
  end

  test "an out-of-service loop's tick touches nothing" do
    state = init(1)
    LoopIntent.set_stopped(1)

    # No mocks are queued: any read or pump command would raise.
    assert {:noreply, ^state} = SecondaryFill.handle_info({:tick, @tick}, state)
  end
end
