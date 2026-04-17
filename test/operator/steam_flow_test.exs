defmodule AutoNuke.Operator.SteamFlowTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.SteamFlow
  alias AutoNuke.Operator.SteamFlow.Turbine
  alias AutoNuke.Test.MockGenServer
  alias AutoNuke.Test.TurbineFactory
  alias AutoNuke.Test.MockAPI, as: API

  @tick AutoNuke.Operator.assigned_tick(SteamFlow)..10000//5

  describe "axis_to_total_power/2" do
    test "is power level 2 for min axis" do
      assert SteamFlow.axis_to_total_power(-1.0, 1) == 2
    end

    test "is power level 16 for mid-axis" do
      assert SteamFlow.axis_to_total_power(+0.0, 1) == 16
    end

    test "is power level 30 for max axis" do
      assert SteamFlow.axis_to_total_power(+1.0, 1) == 30
    end

    test "is based on the number of turbines" do
      assert SteamFlow.axis_to_total_power(-1.0, 1) == 2
      assert SteamFlow.axis_to_total_power(-1.0, 2) == 4
      assert SteamFlow.axis_to_total_power(-1.0, 3) == 6
      assert SteamFlow.axis_to_total_power(1.0, 1) == 30
      assert SteamFlow.axis_to_total_power(1.0, 2) == 60
      assert SteamFlow.axis_to_total_power(1.0, 3) == 90
    end
  end

  describe "total_power_to_axis/2" do
    test "is min axis for power level 2" do
      assert SteamFlow.total_power_to_axis(2, 1) == -1.0
    end

    test "is roughly mid-axis for power level 16" do
      assert_in_delta SteamFlow.total_power_to_axis(16, 1), -0.01, 0.01
    end

    test "is max axis for power level 30" do
      assert SteamFlow.total_power_to_axis(30, 1) == +1.0
    end

    test "is based on the number of turbines" do
      assert SteamFlow.total_power_to_axis(2, 1) == -1.0
      assert SteamFlow.total_power_to_axis(4, 2) == -1.0
      assert SteamFlow.total_power_to_axis(6, 3) == -1.0

      assert SteamFlow.total_power_to_axis(30, 1) == +1.0
      assert SteamFlow.total_power_to_axis(60, 2) == +1.0
      assert SteamFlow.total_power_to_axis(90, 3) == +1.0

      assert_in_delta SteamFlow.total_power_to_axis(32, 2), 0, 0.01
      assert_in_delta SteamFlow.total_power_to_axis(32, 3), -0.38, 0.01
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

  describe "tick with three loops of equal capacity" do
    setup do
      pump = [200, 300, 600] |> Enum.random()

      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3, primary_pump: pump],
            turbine2: [power_level: 5, primary_pump: pump],
            turbine3: [power_level: 4, primary_pump: pump]
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      # Steam output and pressure gets queried by `Turbine.tick/1`, but we don't care.
      0..2
      |> Enum.each(fn n ->
        API.mock_get("STEAM_GEN_#{n}_OUTLET", 1000, times: :any)
        API.mock_get("COOLANT_SEC_#{n}_PRESSURE", 60, times: :any)
      end)

      assert power_levels(pid) == [3, 5, 4]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 100% of demand (MW).
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) / 1000)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [3, 5, 4]
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 1.30 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert total_power(pid) > 12
      # Only loops 1 and 3 are increased.  Loop 2 is already high enough.
      assert power1 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert power3 = API.mock_put_value("MSCV_2_OPENING_ORDERED")
      assert [^power1, 5, ^power3] = powers = power_levels(pid)

      # No level should be more than 1 greater than the others.
      assert Enum.max(powers) - Enum.min(powers) <= 1
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 0.80 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert total_power(pid) < 12
      # Only loops 2 and 3 are decreased, loop 1 is low enough already.
      assert API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED")
      assert powers = power_levels(pid)

      # No level should be more than 1 greater than the others.
      assert Enum.max(powers) - Enum.min(powers) <= 1
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 2.0 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 44, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 60, times: 2)
      API.mock_get("STEAM_GEN_2_OUTLET", 46, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [5, 7, 6]
    end

    test "takes the plant's own used power into account", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      # Ensure supply (kW) is 100% of demand (MW) ...
      total_kw = kw1 + kw2 + kw3
      demand_tracker_mocks(demand_mw: total_kw / 1000)
      # ... but pretend the plant requires a truly excessive amount of power (25%):
      API.mock_get("POWER_FROM_TURBINE_KW", total_kw / 4)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})
      assert total_power(pid) > 12
    end

    test "uses override target if set", %{pid: pid} do
      assert total_power(pid) == 12

      kw1 = :rand.uniform() * 25000
      kw2 = :rand.uniform() * 25000
      kw3 = :rand.uniform() * 25000
      # Demand is picked up by DemandTracker on the first run,
      # so it doesn't need to be part of the repeating mocks.
      API.mock_get("POWER_DEMAND_MW", (kw1 + kw2 + kw3) / 1000)

      mock_power = fn ->
        API.mock_get("GENERATOR_0_KW", kw1)
        API.mock_get("GENERATOR_1_KW", kw2)
        API.mock_get("GENERATOR_2_KW", kw3)
        API.mock_get("POWER_FROM_TURBINE_KW", 0)
        demand_tracker_mocks(demand_mw: nil)
        API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
        API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
        API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
        API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
        API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
        API.mock_get("COOLANT_SEC_2_PRESSURE", 60)
      end

      # Tick 1, nothing changes:
      mock_power.()
      send(pid, {:tick, Enum.random(@tick)})
      assert total_power(pid) == 12

      # Tick 2, nothing changes:
      mock_power.()
      send(pid, {:tick, Enum.random(@tick)})
      assert total_power(pid) == 12

      # Tick 3, we override the target to 130%:
      SteamFlow.set_target_override(130, :never, pid)
      mock_power.()
      send(pid, {:tick, Enum.random(@tick)})
      assert total_power(pid) > 12
    end
  end

  describe "tick with three loops of uneven capacity" do
    setup do
      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3, primary_pump: 200],
            turbine2: [power_level: 5, primary_pump: 300],
            turbine3: [power_level: 4, primary_pump: 600]
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      # Steam output and pressure gets queried by `Turbine.tick/1`, but we don't care.
      0..2
      |> Enum.each(fn n ->
        API.mock_get("STEAM_GEN_#{n}_OUTLET", 1000, times: :any)
        API.mock_get("COOLANT_SEC_#{n}_PRESSURE", 60, times: :any)
      end)

      assert power_levels(pid) == [3, 5, 4]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 100% of demand (MW).
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) / 1000)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [3, 5, 4]
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 1.30 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert total_power(pid) > 12
      # Only loops 3 is increased, because it has much higher capacity.
      assert 7 = API.mock_put_value("MSCV_2_OPENING_ORDERED")
      assert [3, 5, 7] = power_levels(pid)
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 0.80 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert total_power(pid) < 12
      # Only loops 1 and 2 are decreased, 
      # loop 3 (with its high capacity) is low enough already.
      assert 2 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert 3 = API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert [2, 3, 4] = power_levels(pid)
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 2.0 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 44, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 60, times: 2)
      API.mock_get("STEAM_GEN_2_OUTLET", 46, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [5, 7, 6]
    end
  end

  describe "tick with two loops of equal capacity" do
    setup do
      pump = [200, 300, 600] |> Enum.random()

      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3, primary_pump: pump],
            turbine2: [power_level: 5, primary_pump: pump],
            turbine3: false
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      # Steam output and pressure gets queried by `Turbine.tick/1`, but we don't care.
      0..1
      |> Enum.each(fn n ->
        API.mock_get("STEAM_GEN_#{n}_OUTLET", 1000, times: :any)
        API.mock_get("COOLANT_SEC_#{n}_PRESSURE", 60, times: :any)
      end)

      assert power_levels(pid) == [3, 5]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 99.9% of demand (MW).
      demand_tracker_mocks(demand_mw: (kw1 + kw2) / 1000)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [3, 5]
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 8
      assert [old_power1, old_power2] = power_levels(pid)

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2) * 1.20 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert total_power(pid) > 8
      assert new_power1 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert new_power1 > old_power1
      assert [^new_power1, ^old_power2] = power_levels(pid)
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 8

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2) * 0.80 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert total_power(pid) < 8
      # Loop 1 is already low enough, was not decreased.
      assert API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert [power1, power2] = power_levels(pid)

      # Levels should be within 1 of each other:
      assert abs(power1 - power2) in 0..1
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 8

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2) * 2.0 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 34, times: 2)
      API.mock_get("STEAM_GEN_1_OUTLET", 75, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

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
      # Steam output and pressure gets queried by `Turbine.tick/1`, but we don't care.
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: :any)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60, times: :any)

      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 100% of demand (MW).
      demand_tracker_mocks(demand_mw: kw3 / 1000)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [4]
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: kw3 * 1.20 / 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert [power3] = power_levels(pid)
      assert power3 > 4
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == power3
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: kw3 * 0.80 / 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: 2)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

      assert [power3] = power_levels(pid)
      assert power3 < 4
      # This could fail if tuning ever drops us down to power level 1 (MSCV 2).
      # However, I don't think "20% lower demand" should ever drop us from 4 to 1.
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == power3
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: kw3 * 2.0 / 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 46, times: 2)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)

      send(pid, {:tick, Enum.random(@tick)})

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

    # These are fake, only used for startup.
    # Actual time and demand will be set by `demand_tracker_mocks/1` later.
    API.mock_get("TIME_STAMP", 0)
    API.mock_get("POWER_DEMAND_MW", 0)

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

  defp ignore_bypass_mock_puts(mocks) do
    mocks
    |> Enum.reject(fn
      {:put, key, _} -> key =~ ~r"STEAM_TURBINE_[0-2]_BYPASS_ORDERED"
      _ -> false
    end)
  end

  defp demand_tracker_mocks(opts) do
    {demand, opts} = Keyword.pop(opts, :demand_mw)
    {minute, opts} = Keyword.pop(opts, :minute, 0)
    {resistors, opts} = Keyword.pop(opts, :resistors_mw, 0)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    API.mock_get("TIME_STAMP", 60 + minute)
    unless is_nil(demand), do: API.mock_get("POWER_DEMAND_MW", demand)
    unless is_nil(resistors), do: API.mock_get("RES_ABSORPTION_CAPACITY_MW", resistors)
  end
end
