defmodule AutoNuke.Operator.EmergencyPowerTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.EmergencyPower
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(EmergencyPower)

  setup do
    start_supervised!(PubSub)
    :ok
  end

  defp init(statuses \\ ["INACTIVO", "INACTIVO"]) do
    mock_statuses(statuses)
    MockAPI.mock_get("EMERGENCY_BATTERIES_MODE", 1)
    {:ok, state} = EmergencyPower.init(nil)
    state
  end

  defp mock_statuses([s1, s2]) do
    MockAPI.mock_get("EMERGENCY_GENERATOR_1_STATUS", s1)
    MockAPI.mock_get("EMERGENCY_GENERATOR_2_STATUS", s2)
  end

  # Every tick reads both statuses; health reads fuel/maintenance for
  # installed generators only.
  defp tick(state, supply, statuses \\ ["INACTIVO", "INACTIVO"]) do
    Enum.each(supply, fn {key, value} -> MockAPI.mock_get(key, value) end)
    mock_statuses(statuses)

    [s1, s2] = statuses

    for {gen, status} <- [{1, s1}, {2, s2}], status != "null" do
      MockAPI.mock_get("EMERGENCY_GENERATOR_#{gen}_FUEL", 500.0)
      MockAPI.mock_get("EMERGENCY_GENERATOR_#{gen}_MAINTENANCE_NEEDED", "False")
    end

    {:noreply, state} = EmergencyPower.handle_info({:tick, @tick}, state)
    state
  end

  defp normal_mocks do
    [{"POWER_FROM_EXTERNAL_KW", 120.0}, {"POWER_FROM_TURBINE_KW", 0.0}]
  end

  defp blackout_mocks do
    [{"POWER_FROM_EXTERNAL_KW", 0.0}, {"POWER_FROM_TURBINE_KW", 0.0}]
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
      |> tick(blackout_mocks())

    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_1_START_STOP") == "START"
    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_2_START_STOP") == "START"
    assert state.started_by_us == [1, 2]
  end

  test "only installed generators are started" do
    uninstalled_2 = ["INACTIVO", "null"]

    state =
      init(uninstalled_2)
      |> tick(blackout_mocks(), uninstalled_2)
      |> tick(blackout_mocks(), uninstalled_2)
      |> tick(blackout_mocks(), uninstalled_2)

    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_1_START_STOP") == "START"
    refute_put("EMERGENCY_GENERATOR_2_START_STOP")
    assert state.started_by_us == [1]
  end

  test "no installed backup hardware means no commands and no crash" do
    none = ["null", "null"]

    init(none)
    |> tick(blackout_mocks(), none)
    |> tick(blackout_mocks(), none)
    |> tick(blackout_mocks(), none)
    |> tick(blackout_mocks(), none)

    refute_put("EMERGENCY_GENERATOR_1_START_STOP")
    refute_put("EMERGENCY_GENERATOR_2_START_STOP")
  end

  test "recovery stops only the generators we started" do
    state =
      init()
      |> tick(blackout_mocks())
      |> tick(blackout_mocks())
      |> tick(blackout_mocks())

    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_1_START_STOP") == "START"
    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_2_START_STOP") == "START"

    # Gens run through the recovery; 5 sustained normal ticks stop them.
    running = ["ACTIVO", "ACTIVO"]
    state = Enum.reduce(1..5, state, fn _, acc -> tick(acc, normal_mocks(), running) end)

    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_1_START_STOP") == "STOP"
    assert MockAPI.mock_put_value("EMERGENCY_GENERATOR_2_START_STOP") == "STOP"
    assert state.started_by_us == []
  end

  test "manually running generators are never stopped" do
    state = init()

    # Normal supply the whole time, gen 1 running by hand:
    state =
      Enum.reduce(1..6, state, fn _, acc ->
        tick(acc, normal_mocks(), ["ACTIVO", "INACTIVO"])
      end)

    refute_put("EMERGENCY_GENERATOR_1_START_STOP")
    assert state.started_by_us == []
  end
end
