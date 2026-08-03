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

  test "sustained overproduction enables main switch and installed banks" do
    state = init() |> tick(1.10) |> tick(1.10)

    # Third consecutive high tick checks and flips the switches:
    MockAPI.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
    MockAPI.mock_get("RESISTOR_BANKS_JSON", @banks_json)
    tick(state, 1.10)

    assert MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH") == true
    assert MockAPI.mock_put_value("RESISTOR_BANK_01_SWITCH") == true
    assert MockAPI.mock_put_value("RESISTOR_BANK_02_SWITCH") == true
    refute_put("RESISTOR_BANK_03_SWITCH")
  end

  test "a brief spike does not enable anything" do
    init() |> tick(1.10) |> tick(1.10) |> tick(1.05)

    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end

  test "already-enabled banks are left alone on the high trigger" do
    state = init() |> tick(1.10) |> tick(1.10)

    MockAPI.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "True")
    tick(state, 1.10)

    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end

  test "a long calm stretch disables the banks" do
    state = init()

    state = Enum.reduce(1..29, state, fn _, acc -> tick(acc, 1.00) end)

    MockAPI.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "True")
    tick(state, 1.00)

    assert MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH") == false
    assert MockAPI.mock_put_value("RESISTOR_BANK_01_SWITCH") == false
    assert MockAPI.mock_put_value("RESISTOR_BANK_04_SWITCH") == false
  end

  test "mid-band ratios reset both streaks" do
    state = init()
    state = Enum.reduce(1..29, state, fn _, acc -> tick(acc, 1.00) end)

    # One mid-band tick resets the calm streak; the 31st calm tick must
    # not disable.
    state = tick(state, 1.06)
    tick(state, 1.00)

    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end
end
