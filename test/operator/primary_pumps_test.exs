defmodule AutoNuke.Operator.PrimaryPumpsTest do
  use ExUnit.Case, async: false

  alias AutoNuke.LoopIntent
  alias AutoNuke.Operator.PrimaryPumps
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(PrimaryPumps)

  setup do
    start_supervised!(PubSub)
    start_supervised!(LoopIntent)
    :ok
  end

  defp init do
    for pump <- 0..2 do
      MockAPI.mock_get("COOLANT_CORE_CIRCULATION_PUMP_#{pump}_ORDERED_SPEED", 20)
    end

    MockAPI.mock_get("CORE_TEMP", 340.0)
    {:ok, state} = PrimaryPumps.init(nil)
    state
  end

  # A big target change forces a speed command on the next tick.
  defp force_speed_change(state) do
    {:noreply, state} = PrimaryPumps.handle_info({:core_temp, 390.0}, state)
    {:noreply, state} = PrimaryPumps.handle_info({:tick, @tick}, state)
    state
  end

  test "drives all pumps when every loop is in service" do
    init() |> force_speed_change()

    for pump <- 0..2 do
      assert MockAPI.mock_put_value("COOLANT_CORE_CIRCULATION_PUMP_#{pump}_ORDERED_SPEED") == 45
    end
  end

  test "does not drive the pump of an out-of-service loop" do
    state = init()
    LoopIntent.set_stopped(3)
    force_speed_change(state)

    assert MockAPI.mock_put_value("COOLANT_CORE_CIRCULATION_PUMP_0_ORDERED_SPEED") == 45
    assert MockAPI.mock_put_value("COOLANT_CORE_CIRCULATION_PUMP_1_ORDERED_SPEED") == 45

    assert_raise RuntimeError, ~r/not received/, fn ->
      MockAPI.mock_put_value("COOLANT_CORE_CIRCULATION_PUMP_2_ORDERED_SPEED")
    end
  end
end
