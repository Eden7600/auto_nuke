defmodule AutoNuke.Operator.EmergencyPowerTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.EmergencyPower
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(EmergencyPower)

  setup do
    start_supervised!(PubSub)
    :ok
  end

  defp init do
    {:ok, state} = EmergencyPower.init(nil)
    state
  end

  defp tick(state, mocks) do
    Enum.each(mocks, fn {key, value} -> MockAPI.mock_get(key, value) end)
    # Health checks read fuel/maintenance every tick:
    MockAPI.mock_get("EMERGENCY_GENERATOR_1_FUEL", 500.0)
    MockAPI.mock_get("EMERGENCY_GENERATOR_2_FUEL", 500.0)
    MockAPI.mock_get("EMERGENCY_GENERATOR_1_MAINTENANCE_NEEDED", "False")
    MockAPI.mock_get("EMERGENCY_GENERATOR_2_MAINTENANCE_NEEDED", "False")

    {:noreply, state} = EmergencyPower.handle_info({:tick, @tick}, state)
    state
  end

  defp normal_mocks do
    [{"POWER_FROM_EXTERNAL_KW", 120.0}, {"POWER_FROM_TURBINE_KW", 0.0}]
  end

  # Generator statuses are only read on the tick that acts (start/stop) —
  # mock them on exactly those ticks or leftovers shadow later reads.
  defp blackout_mocks do
    [{"POWER_FROM_EXTERNAL_KW", 0.0}, {"POWER_FROM_TURBINE_KW", 0.0}]
  end

  defp statuses(status) do
    [
      {"EMERGENCY_GENERATOR_1_STATUS", status},
      {"EMERGENCY_GENERATOR_2_STATUS", status}
    ]
  end

  defp refute_put(key) do
    assert_raise RuntimeError, ~r/not received/, fn -> MockAPI.mock_put_value(key) end
  end

  test "normal supply does nothing" do
    init() |> tick(normal_mocks()) |> tick(normal_mocks())
    refute_put("EMERGENCY_GENERATOR_1_START_STOP")
  end

  test "a brief supply blip does not start the generators" do
    init()
    |> tick(blackout_mocks())
    |> tick(blackout_mocks())
    |> tick(normal_mocks())

    refute_put("EMERGENCY_GENERATOR_1_START_STOP")
  end

  test "a sustained blackout starts idle generators" do
    state =
      init()
      |> tick(blackout_mocks())
      |> tick(blackout_mocks())
      |> tick(blackout_mocks() ++ statuses("INACTIVO"))

    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_1_START_STOP") == "START"
    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_2_START_STOP") == "START"
    assert state.started_by_us == [1, 2]
  end

  test "recovery stops only the generators we started" do
    state =
      init()
      |> tick(blackout_mocks())
      |> tick(blackout_mocks())
      |> tick(blackout_mocks() ++ statuses("INACTIVO"))

    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_1_START_STOP") == "START"
    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_2_START_STOP") == "START"

    # Gens run through the blackout; recovery needs 5 sustained normal
    # ticks, and only the 5th reads the statuses.
    state = Enum.reduce(1..4, state, fn _, acc -> tick(acc, normal_mocks()) end)
    state = tick(state, normal_mocks() ++ statuses("ACTIVO"))

    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_1_START_STOP") == "STOP"
    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_2_START_STOP") == "STOP"
    assert state.started_by_us == []
  end

  test "manually running generators are never stopped" do
    state = init()

    # Normal supply the whole time; the operator never started anything,
    # so it never even looks at (or stops) the hand-started generator.
    state = Enum.reduce(1..6, state, fn _, acc -> tick(acc, normal_mocks()) end)

    refute_put("EMERGENCY_GENERATOR_1_START_STOP")
    assert state.started_by_us == []
  end
end
