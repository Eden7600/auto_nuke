defmodule AutoNuke.Operator.SteamFlowTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.SteamFlow
  alias AutoNuke.Operator.SteamFlow.Turbine
  alias AutoNuke.Test.MockGenServer
  alias AutoNuke.Test.TurbineFactory
  alias AutoNuke.Test.MockAPI, as: API

  describe "axis_to_total_power/2" do
    test "is power level 1 for min axis" do
      assert SteamFlow.axis_to_total_power(-1.0, 1) == 1
    end

    test "is power level 50 for roughly mid-axis" do
      assert SteamFlow.axis_to_total_power(-0.01, 1) == 50
    end

    test "is power level 100 for max axis" do
      assert SteamFlow.axis_to_total_power(+1.0, 1) == 100
    end

    test "is based on the number of turbines" do
      assert SteamFlow.axis_to_total_power(-1.0, 1) == 1
      assert SteamFlow.axis_to_total_power(-1.0, 2) == 2
      assert SteamFlow.axis_to_total_power(-1.0, 3) == 3
      assert SteamFlow.axis_to_total_power(1.0, 1) == 100
      assert SteamFlow.axis_to_total_power(1.0, 2) == 200
      assert SteamFlow.axis_to_total_power(1.0, 3) == 300
    end
  end

  describe "total_power_to_axis/2" do
    test "is min axis for power level 1" do
      assert SteamFlow.total_power_to_axis(1, 1) == -1.0
    end

    test "is roughly mid-axis for power level 50" do
      assert_in_delta SteamFlow.total_power_to_axis(50, 1), -0.01, 0.01
    end

    test "is power level 100 for max axis" do
      assert SteamFlow.total_power_to_axis(100, 1) == +1.0
    end

    test "is based on the number of turbines" do
      assert SteamFlow.total_power_to_axis(1, 1) == -1.0
      assert SteamFlow.total_power_to_axis(2, 2) == -1.0
      assert SteamFlow.total_power_to_axis(3, 3) == -1.0

      assert SteamFlow.total_power_to_axis(100, 1) == +1.0
      assert SteamFlow.total_power_to_axis(200, 2) == +1.0
      assert SteamFlow.total_power_to_axis(300, 3) == +1.0

      assert_in_delta SteamFlow.total_power_to_axis(100, 2), -0.01, 0.01
      assert_in_delta SteamFlow.total_power_to_axis(100, 3), -0.35, 0.01
    end
  end

  describe "start_link/1" do
    test "takes control of turbines with closed breakers" do
      pid =
        start_steam_flow(
          turbine1: [power_level: 5, bypass: 5],
          turbine2: false,
          turbine3: [power_level: 3, bypass: 10]
        )

      assert [t1, t3] = state(pid).turbines

      assert t1.loop == 1
      assert t1.power_level == 5
      assert t1.min_steam == 25
      assert t1.bypass == 5

      assert t3.loop == 3
      assert t3.power_level == 3
      assert t3.min_steam == 25
      assert t3.bypass == 10
    end
  end

  describe "add_loop/1" do
    setup do
      [pid: start_steam_flow(turbine1: false, turbine3: false)]
    end

    test "begins managing new turbine", %{pid: pid} do
      # Start with just turbine 2:
      assert [%Turbine{loop: 2}] = state(pid).turbines

      # Add turbine 1:
      TurbineFactory.create(loop: 1, mock_only: true)
      assert :ok = SteamFlow.add_loop(1, pid)

      # Verify we have turbines 1 and 2:
      assert [%Turbine{loop: 1}, %Turbine{loop: 2}] = state(pid).turbines
    end

    test "updates minimum steam flow on all turbines", %{pid: pid} do
      assert [%Turbine{min_steam: 50.0}] = state(pid).turbines

      TurbineFactory.create(loop: 1, mock_only: true)
      assert :ok = SteamFlow.add_loop(1, pid)
      assert [%Turbine{min_steam: 25.0}, %Turbine{min_steam: 25.0}] = state(pid).turbines

      TurbineFactory.create(loop: 3, mock_only: true)
      assert :ok = SteamFlow.add_loop(3, pid)
      assert [t1, t2, t3] = state(pid).turbines
      assert_in_delta t1.min_steam, 16.66666, 0.0001
      assert_in_delta t2.min_steam, 16.66666, 0.0001
      assert_in_delta t3.min_steam, 16.66666, 0.0001
    end

    test "returns error when turbine already added", %{pid: pid} do
      assert {:error, :already_active} = SteamFlow.add_loop(2, pid)
    end
  end

  describe "remove_loop/1" do
    setup do
      [pid: start_steam_flow(turbine1: false)]
    end

    test "stops managing specified turbine", %{pid: pid} do
      # Start with turbines 2 and 3:
      assert [%Turbine{loop: 2}, %Turbine{loop: 3}] = state(pid).turbines

      # Remove turbine 2:
      assert :ok = SteamFlow.remove_loop(2, pid)

      # Verify we have only turbine 3:
      assert [%Turbine{loop: 3}] = state(pid).turbines
    end

    test "returns error when turbine not active", %{pid: pid} do
      assert {:error, :not_active} = SteamFlow.remove_loop(1, pid)
    end

    test "updates minimum steam flow on all turbines", %{pid: pid} do
      # Verify old steam flow:
      assert [%Turbine{min_steam: 25.0}, %Turbine{min_steam: 25.0}] = state(pid).turbines

      # Remove turbine 3:
      assert :ok = SteamFlow.remove_loop(3, pid)

      # Verify minimum steam flow has increased:
      assert [%Turbine{min_steam: 50.0}] = state(pid).turbines
    end
  end

  describe "tick with three loops" do
    setup do
      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3],
            turbine2: [power_level: 5],
            turbine3: [power_level: 4]
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      assert power_levels(pid) == [3, 5, 4]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 105% of demand (MW).
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2 + kw3) / 1.05 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      # Steam output should NOT be queried, no need to mock it.

      send(pid, {:tick, 1})

      assert power_levels(pid) == [3, 5, 4]
      assert [] = API.unused_mocks()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2 + kw3) * 1.20 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_0_OUTLET", 1000)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000)

      send(pid, {:tick, 1})

      assert total_power(pid) > 12
      assert power1 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      # Loops 2 and 3 were likely not increased.
      assert [^power1, _, _] = powers = power_levels(pid)

      # No level should be more than 1 greater than the others.
      assert Enum.max(powers) - Enum.min(powers) <= 1
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2 + kw3) * 0.80 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_0_OUTLET", 1000)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000)

      send(pid, {:tick, 1})

      assert total_power(pid) < 12
      # Only loop 2 is decreased, the others are low enough already.
      assert API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert powers = power_levels(pid)

      # No level should be more than 1 greater than the others.
      assert Enum.max(powers) - Enum.min(powers) <= 1
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2 + kw3) * 2.0 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_0_OUTLET", 44)
      API.mock_get("STEAM_GEN_1_OUTLET", 60)
      API.mock_get("STEAM_GEN_2_OUTLET", 46)

      send(pid, {:tick, 1})

      assert power_levels(pid) == [5, 7, 6]
    end

    test "takes the plant's own used power into account", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      # Ensure supply (kW) is 105% of demand (MW) ...
      total_kw = kw1 + kw2 + kw3
      API.mock_get("POWER_DEMAND_MW", total_kw / 1.05 / 1000)
      # ... but pretend the plant requires a truly excessive amount of power (25%):
      API.mock_get("POWER_FROM_TURBINE_KW", total_kw / 4)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_0_OUTLET", 1000)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000)

      send(pid, {:tick, 1})
      assert total_power(pid) > 12
    end

    test "targets below 100% if resistor banks enabled", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 100.1% of demand (MW) ...
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2 + kw3) / 1.001 / 1000)
      # ... but now we turn the main banks on:
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "True")
      API.mock_get("STEAM_GEN_0_OUTLET", 1000)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000)

      send(pid, {:tick, 1})
      assert total_power(pid) < 12
    end

    test "uses override target if set", %{pid: pid} do
      assert total_power(pid) == 12

      kw1 = :rand.uniform() * 25000
      kw2 = :rand.uniform() * 25000
      kw3 = :rand.uniform() * 25000
      demand_mw = (kw1 + kw2 + kw3) / 1.05 / 1000

      mock_power = fn ->
        API.mock_get("GENERATOR_0_KW", kw1)
        API.mock_get("GENERATOR_1_KW", kw2)
        API.mock_get("GENERATOR_2_KW", kw3)
        API.mock_get("POWER_FROM_TURBINE_KW", 0)
        API.mock_get("POWER_DEMAND_MW", demand_mw)
        API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
        API.mock_get("STEAM_GEN_0_OUTLET", 1000)
        API.mock_get("STEAM_GEN_1_OUTLET", 1000)
        API.mock_get("STEAM_GEN_2_OUTLET", 1000)
      end

      # Tick 1, nothing changes:
      mock_power.()
      send(pid, {:tick, 1})
      assert total_power(pid) == 12

      # Tick 2, nothing changes:
      mock_power.()
      send(pid, {:tick, 1})
      assert total_power(pid) == 12

      # Tick 3, we override the target to 1.3:
      SteamFlow.set_target_override(1.3, pid)
      mock_power.()
      send(pid, {:tick, 1})
      assert total_power(pid) > 12
    end
  end

  describe "tick with two loops" do
    setup do
      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3],
            turbine2: [power_level: 5],
            turbine3: false
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      assert power_levels(pid) == [3, 5]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 105% of demand (MW).
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2) / 1.05 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      # Steam output should NOT be queried, no need to mock it.

      send(pid, {:tick, 1})

      assert power_levels(pid) == [3, 5]
      assert [] = API.unused_mocks()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 8
      assert [old_power1, old_power2] = power_levels(pid)

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2) * 1.20 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_0_OUTLET", 1000)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000)

      send(pid, {:tick, 1})

      assert total_power(pid) > 8
      assert new_power1 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert new_power1 > old_power1
      assert [^new_power1, ^old_power2] = power_levels(pid)
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 8

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2) * 0.80 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_0_OUTLET", 1000)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000)

      send(pid, {:tick, 1})

      assert total_power(pid) < 8
      # Loop 1 is already low enough, was not decreased.
      assert API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert [power1, power2] = power_levels(pid)

      # Levels should be within 1 of each other:
      assert abs(power1 - power2) in 0..1
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 8

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2) * 2.0 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_0_OUTLET", 34)
      API.mock_get("STEAM_GEN_1_OUTLET", 75)

      send(pid, {:tick, 1})

      assert power_levels(pid) == [4, 9]
    end
  end

  describe "tick with one loop" do
    setup do
      [
        pid:
          start_steam_flow(
            turbine1: false,
            turbine2: false,
            turbine3: [power_level: 4]
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 105% of demand (MW).
      API.mock_get("POWER_DEMAND_MW", kw3 / 1.05 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      # Steam output should NOT be queried, no need to mock it.

      send(pid, {:tick, 1})

      assert power_levels(pid) == [4]
      assert [] = API.unused_mocks()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", kw3 * 1.20 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_2_OUTLET", 1000)

      send(pid, {:tick, 1})

      assert [power3] = power_levels(pid)
      assert power3 > 4
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == power3
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", kw3 * 0.80 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_2_OUTLET", 1000)

      send(pid, {:tick, 1})

      assert [power3] = power_levels(pid)
      assert power3 < 4
      # This could fail if tuning ever drops us down to power level 1 (MSCV 2).
      # However, I don't think "20% lower demand" should ever drop us from 4 to 1.
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == power3
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      API.mock_get("POWER_DEMAND_MW", kw3 * 2.0 / 1000)
      API.mock_get("RESISTOR_BANKS_MAIN_SWITCH", "False")
      API.mock_get("STEAM_GEN_2_OUTLET", 46)

      send(pid, {:tick, 1})

      assert power_levels(pid) == [6]
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == 6
    end
  end

  defp start_steam_flow(opts) do
    {turbine1, opts} = Keyword.pop(opts, :turbine1, [])
    {turbine2, opts} = Keyword.pop(opts, :turbine2, [])
    {turbine3, opts} = Keyword.pop(opts, :turbine3, [])
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    [turbine1, turbine2, turbine3]
    |> Enum.with_index(1)
    |> Enum.each(fn
      {false, loop} ->
        API.mock_get("GENERATOR_#{loop - 1}_BREAKER", "True")

      {t_opts, loop} when is_list(t_opts) ->
        API.mock_get("GENERATOR_#{loop - 1}_BREAKER", "False")

        t_opts
        |> Keyword.put(:mock_only, true)
        |> Keyword.put(:loop, loop)
        |> TurbineFactory.create()
    end)

    test_pid = self()

    mock_pid =
      start_link_supervised!(
        {MockGenServer,
         module: SteamFlow,
         before_init: fn ->
           API.register_alias(self(), test_pid)
         end}
      )

    assert [] = API.unused_mocks()
    mock_pid
  end

  defp state(pid) do
    assert %SteamFlow.State{} = MockGenServer.get_state(pid)
  end

  defp power_levels(pid), do: state(pid).turbines |> Enum.map(& &1.power_level)
  defp total_power(pid), do: power_levels(pid) |> Enum.sum()
end
