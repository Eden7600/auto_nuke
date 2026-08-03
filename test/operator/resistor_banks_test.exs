defmodule AutoNuke.Operator.ResistorBanksTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.ResistorBanks
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(ResistorBanks)

  setup do
    start_supervised!(PubSub)
    :ok
  end

  defp init do
    {:ok, state} = ResistorBanks.init(nil)
    state
  end

  # Supply ratio = (generators - own draw) / demand.
  defp tick(state, ratio) do
    MockAPI.mock_get("POWER_DEMAND_MW", 100.0)
    MockAPI.mock_get("GENERATOR_0_KW", ratio * 100_000 + 1_000)
    MockAPI.mock_get("GENERATOR_1_KW", "null")
    MockAPI.mock_get("GENERATOR_2_KW", "null")
    MockAPI.mock_get("POWER_FROM_TURBINE_KW", 1_000.0)

    {:noreply, state} = ResistorBanks.handle_info({:tick, @tick}, state)
    state
  end

  defp refute_put(key) do
    assert_raise RuntimeError, ~r/not received/, fn -> MockAPI.mock_put_value(key) end
  end

  @banks_json Jason.encode!(%{
                "resistors" => %{
                  "Resistor_Bank_01" => %{"IsInstalled" => 1},
                  "Resistor_Bank_02" => %{"IsInstalled" => 1},
                  "Resistor_Bank_03" => %{"IsInstalled" => 0},
                  "Resistor_Bank_04" => %{"IsInstalled" => 0}
                }
              })

  # With SteamFlow not running, the operator assumes a target of 1.0 —
  # the on-trigger is |ratio - 1.0| > 0.10.

  test "sustained overproduction enables main switch and installed banks" do
    state = init() |> tick(1.12) |> tick(1.12)

    # Third consecutive outside tick checks and flips the switches:
    MockAPI.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
    MockAPI.mock_get("RESISTOR_BANKS_JSON", @banks_json)
    tick(state, 1.12)

    assert MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH") == true
    assert MockAPI.mock_put_value("RESISTOR_BANK_01_SWITCH") == true
    assert MockAPI.mock_put_value("RESISTOR_BANK_02_SWITCH") == true
    refute_put("RESISTOR_BANK_03_SWITCH")
  end

  test "sustained undersupply also enables the banks" do
    state = init() |> tick(0.85) |> tick(0.85)

    MockAPI.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
    MockAPI.mock_get("RESISTOR_BANKS_JSON", @banks_json)
    tick(state, 0.85)

    assert MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH") == true
  end

  test "a brief spike does not enable anything" do
    init() |> tick(1.12) |> tick(1.12) |> tick(1.02)

    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end

  test "already-enabled banks are left alone on the outside trigger" do
    state = init() |> tick(1.12) |> tick(1.12)

    MockAPI.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "True")
    tick(state, 1.12)

    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end

  test "a long on-target stretch disables the banks" do
    state = init()

    state = Enum.reduce(1..29, state, fn _, acc -> tick(acc, 1.02) end)

    MockAPI.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "True")
    tick(state, 1.02)

    assert MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH") == false
    assert MockAPI.mock_put_value("RESISTOR_BANK_01_SWITCH") == false
    assert MockAPI.mock_put_value("RESISTOR_BANK_04_SWITCH") == false
  end

  test "hysteresis-margin ratios reset both streaks" do
    state = init()
    state = Enum.reduce(1..29, state, fn _, acc -> tick(acc, 1.02) end)

    # A tick in the 8-10% deviation margin resets the calm streak; the
    # 31st on-target tick must not disable.
    state = tick(state, 1.09)
    tick(state, 1.02)

    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end
end
