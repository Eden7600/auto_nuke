defmodule AutoNuke.Operator.XenonGuardTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.XenonGuard
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(XenonGuard)

  defmodule StubSteamFlow do
    use GenServer

    def start(owner, override \\ nil) do
      GenServer.start(__MODULE__, {owner, override}, name: AutoNuke.Operator.SteamFlow)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get_override, _from, {_owner, override} = state) do
      {:reply, override, state}
    end

    @impl true
    def handle_call(msg, _from, {owner, _} = state) do
      send(owner, {:steam_flow_call, msg})
      {:reply, :ok, state}
    end
  end

  setup do
    start_supervised!(PubSub)
    MockAPI.mock_get("TIME_STAMP", 100, times: :any)
    :ok
  end

  defp init(xenon) do
    MockAPI.mock_get("CORE_XENON_CUMULATIVE", xenon)
    {:ok, state} = XenonGuard.init(nil)
    state
  end

  defp tick(state, xenon, rods) do
    MockAPI.mock_get("CORE_XENON_CUMULATIVE", xenon)
    MockAPI.mock_get("RODS_POS_ACTUAL", rods)
    {:noreply, state} = XenonGuard.handle_info({:tick, @tick}, state)
    state
  end

  defp with_stub(override \\ nil, fun) do
    {:ok, pid} = StubSteamFlow.start(self(), override)

    try do
      fun.()
    after
      GenServer.stop(pid)
    end
  end

  defp mock_banks_json do
    MockAPI.mock_get(
      "RESISTOR_BANKS_JSON",
      Jason.encode!(%{"resistors" => %{"Resistor_Bank_01" => %{"IsInstalled" => 1}}})
    )
  end

  defp refute_put(key) do
    assert_raise RuntimeError, ~r/not received/, fn -> MockAPI.mock_put_value(key) end
  end

  test "rising xenon over threshold with rod margin starts the burn" do
    with_stub(fn ->
      mock_banks_json()
      MockAPI.mock_get("POWER_DEMAND_MW", 100.0)

      state = init(70.0) |> tick(72.0, 50.0)

      assert state.burning
      assert state.our_override
      assert MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH") == true
      assert MockAPI.mock_put_value("RESISTOR_BANK_01_SWITCH") == true

      # Burn power = 110% of the 100 MW demand:
      assert_receive {:steam_flow_call, {:override, {mw, :mw}, _expiry}}
      assert_in_delta mw, 110.0, 0.001
    end)
  end

  test "a user-set override is respected, not replaced" do
    with_stub({{0.5, :ratio}, :never}, fn ->
      mock_banks_json()

      state = init(70.0) |> tick(72.0, 50.0)

      assert state.burning
      refute state.our_override
      refute_receive {:steam_flow_call, {:override, _, _}}
    end)
  end

  test "no burn without rod margin — the spiral alarm fires instead" do
    MockAPI.mock_get("CORE_STATE_CRITICALITY", -0.5)

    state = init(70.0) |> tick(75.0, 3.0)

    refute state.burning
    assert state.next_spiral_alarm > 0
    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end

  test "falling xenon below the exit level ends the burn" do
    with_stub(fn ->
      mock_banks_json()
      MockAPI.mock_get("POWER_DEMAND_MW", 100.0)

      state = init(70.0) |> tick(72.0, 50.0)
      assert state.burning
      assert_receive {:steam_flow_call, {:override, _, _}}

      # Drain the enable puts so the disable puts are unambiguous.
      MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH")
      MockAPI.mock_put_value("RESISTOR_BANK_01_SWITCH")

      state = tick(state, 61.0, 50.0)
      refute state.burning

      # Banks off (bank switches then main):
      assert MockAPI.mock_put_value("RESISTOR_BANK_01_SWITCH") == false
      assert MockAPI.mock_put_value("RESISTOR_BANKS_MAIN_SWITCH") == false
    end)
  end

  test "quiet xenon does nothing" do
    state = init(50.0) |> tick(50.0, 50.0) |> tick(50.1, 50.0)

    refute state.burning
    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
  end
end
