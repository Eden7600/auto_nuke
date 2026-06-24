defmodule AutoNuke.Operator.SteamFlowTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Ticker
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
      assert t1.bypass == 5

      assert t3.loop == 3
      assert t3.power_level == 3
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
  end

  describe "tick with three loops of equal pressure" do
    setup do
      pressure = TurbineFactory.random_pressure()

      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3, pressure: pressure],
            turbine2: [power_level: 5, pressure: pressure],
            turbine3: [power_level: 4, pressure: pressure]
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      assert power_levels(pid) == [3, 5, 4]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 100% of demand (MW).
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [3, 5, 4]
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power evenly when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 1.30 / 1000)
      turbine_mocks(1..3)

      send(pid, {:tick, Enum.random(@tick)})

      assert [4, 6, 5] = power_levels(pid)
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 0.80 / 1000)
      turbine_mocks(1..3)

      send(pid, {:tick, Enum.random(@tick)})

      assert [2, 4, 3] = power_levels(pid)
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 3.0 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 44, times: :any)
      API.mock_get("STEAM_GEN_1_OUTLET", 60, times: :any)
      API.mock_get("STEAM_GEN_2_OUTLET", 46, times: :any)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60, times: :any)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60, times: :any)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60, times: :any)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [5, 7, 6]
    end

    test "does not increase power if turbines are starved for pressure", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 3.0 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 1000, times: :any)
      API.mock_get("STEAM_GEN_1_OUTLET", 1000, times: :any)
      API.mock_get("STEAM_GEN_2_OUTLET", 1000, times: :any)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 54, times: :any)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60, times: :any)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 51, times: :any)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [3, 14, 4]
    end

    test "takes the plant's own used power into account", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      # Ensure supply (kW) is 100% of demand (MW) ...
      total_kw = kw1 + kw2 + kw3
      # ... but pretend the plant requires a truly excessive amount of power (25%):
      API.mock_get("POWER_FROM_TURBINE_KW", total_kw / 4)
      demand_tracker_mocks(demand_mw: total_kw / 1000)
      turbine_mocks(1..3)

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
      turbine_mocks(1..3)

      mock_power = fn ->
        API.mock_get("GENERATOR_0_KW", kw1)
        API.mock_get("GENERATOR_1_KW", kw2)
        API.mock_get("GENERATOR_2_KW", kw3)
        API.mock_get("POWER_FROM_TURBINE_KW", 0)
        demand_tracker_mocks(demand_mw: nil)
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

  describe "tick with three loops of uneven pressure" do
    setup do
      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3, pressure: 64.857],
            turbine2: [power_level: 5, pressure: 58.477],
            turbine3: [power_level: 4, pressure: 61.436]
          )
      ]
    end

    test "rebalances current power even when demand is met", %{pid: pid} do
      assert power_levels(pid) == [3, 5, 4]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 100% of demand (MW).
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      # Loop 1 has high pressure while loop 2 has low pressure,
      # so they get swapped around to help them equalise.
      # (Loop 3 happens to be fairly balanced compared to these two.)
      assert power_levels(pid) == [5, 3, 4]
      assert 5 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert 3 = API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 1.30 / 1000)
      turbine_mocks(1..3)

      send(pid, {:tick, Enum.random(@tick)})

      # Loop 1 gets the brunt of it, being high pressure.
      # Loop 2 is still decreased slightly due to low pressure.
      assert [6, 4, 5] = power_levels(pid)
      assert 6 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert 4 = API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert 5 = API.mock_put_value("MSCV_2_OPENING_ORDERED")
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 0.80 / 1000)
      turbine_mocks(1..3)

      send(pid, {:tick, Enum.random(@tick)})

      assert total_power(pid) < 12
      # Loops 2 and 3 are decreased to increase pressure,
      # but some power is reallocated to the high-pressure loop 1.
      assert [4, 2, 3] = power_levels(pid)
      assert 4 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert 2 = API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert 3 = API.mock_put_value("MSCV_2_OPENING_ORDERED")
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 12

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2 + kw3) * 2.0 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 44, times: :any)
      API.mock_get("STEAM_GEN_1_OUTLET", 60, times: :any)
      API.mock_get("STEAM_GEN_2_OUTLET", 46, times: :any)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60, times: :any)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60, times: :any)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60, times: :any)

      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [5, 7, 6]
    end
  end

  describe "tick with two loops of equal pressure" do
    setup do
      pressure = TurbineFactory.random_pressure()

      [
        pid:
          start_steam_flow(
            turbine1: [power_level: 3, pressure: pressure],
            turbine2: [power_level: 5, pressure: pressure],
            turbine3: false
          )
      ]
    end

    test "maintains current power when demand is met", %{pid: pid} do
      assert power_levels(pid) == [3, 5]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 99.9% of demand (MW).
      demand_tracker_mocks(demand_mw: (kw1 + kw2) / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [3, 5]
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert total_power(pid) == 8
      assert power_levels(pid) == [3, 5]

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2) * 1.20 / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [4, 6]
      assert 4 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert 6 = API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert total_power(pid) == 8

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2) * 0.80 / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      # Both decreased by one:
      assert power_levels(pid) == [2, 4]
      assert 2 = API.mock_put_value("MSCV_0_OPENING_ORDERED")
      assert 4 = API.mock_put_value("MSCV_1_OPENING_ORDERED")
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      assert total_power(pid) == 8

      API.mock_get("GENERATOR_0_KW", kw1 = :rand.uniform() * 25000)
      API.mock_get("GENERATOR_1_KW", kw2 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: (kw1 + kw2) * 2.0 / 1000)
      API.mock_get("STEAM_GEN_0_OUTLET", 34, times: :any)
      API.mock_get("STEAM_GEN_1_OUTLET", 75, times: :any)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60, times: :any)
      API.mock_get("COOLANT_SEC_1_PRESSURE", 60, times: :any)

      turbine_mocks(3)
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
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      # Ensure supply (kW) is 100% of demand (MW).
      demand_tracker_mocks(demand_mw: kw3 / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [4]
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "increases power when supply does not meet demand", %{pid: pid} do
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: kw3 * 1.20 / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      assert [power3] = power_levels(pid)
      assert power3 > 4
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == power3
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "decreases power when supply exceeds demand", %{pid: pid} do
      assert power_levels(pid) == [4]

      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: kw3 * 0.80 / 1000)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      assert [power3] = power_levels(pid)
      assert power3 < 4
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == power3
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end

    test "does not increase power beyond current steam level plus one", %{pid: pid} do
      API.mock_get("GENERATOR_2_KW", kw3 = :rand.uniform() * 25000)
      API.mock_get("POWER_FROM_TURBINE_KW", 0)
      demand_tracker_mocks(demand_mw: kw3 * 2.0 / 1000)
      API.mock_get("STEAM_GEN_2_OUTLET", 46, times: :any)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60, times: :any)

      turbine_mocks()
      send(pid, {:tick, Enum.random(@tick)})

      assert power_levels(pid) == [6]
      assert API.mock_put_value("MSCV_2_OPENING_ORDERED") == 6
      assert [] = API.unused_mocks() |> ignore_bypass_mock_puts()
    end
  end

  defmodule SimState do
    @enforce_keys [:tick, :supplied_total]
    defstruct(@enforce_keys)
  end

  test "tick when simulating an entire hour" do
    pid = start_steam_flow([])

    # Set an arbitrary demand for the entire test.
    API.mock_get("POWER_DEMAND_MW", demand = Enum.random(100..300))
    # Assume resistors are off for this entire test.
    API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0, times: :any)
    # Steam outlet and coolant pressure are outside the scope of this test.
    0..2
    |> Enum.each(fn n ->
      API.mock_get("STEAM_GEN_#{n}_OUTLET", 9999, times: :any)
      API.mock_get("COOLANT_SEC_#{n}_PRESSURE", 62, times: :any)
    end)

    state = %SimState{
      tick: 0,
      supplied_total: 0
    }

    start_time = Enum.random(1..100) * 60

    0..59
    |> Enum.reduce(state, fn minute, %SimState{} = state ->
      1..Ticker.seconds_per_minute()
      |> Enum.reduce(state, fn _, %SimState{} = state ->
        [pl1, pl2, pl3] = power_levels(pid)
        # This second's mocks:
        API.mock_get("TIME_STAMP", start_time + minute)
        API.mock_get("GENERATOR_0_KW", kw1 = random_generator_kw(pl1))
        API.mock_get("GENERATOR_1_KW", kw2 = random_generator_kw(pl2))
        API.mock_get("GENERATOR_2_KW", kw3 = random_generator_kw(pl3))
        API.mock_get("POWER_FROM_TURBINE_KW", kw_used = 200 + Enum.random(1..200))

        # SteamGen should run exactly once during these n ticks:
        1..Ticker.ticks_per_second()
        |> Enum.reduce(state, fn _, %SimState{} = state ->
          send(pid, {:tick, state.tick})
          %SimState{state | tick: state.tick + 1}
        end)
        |> then(fn %SimState{supplied_total: t} = state ->
          # Add generated power to supplied total:
          %SimState{state | supplied_total: t + kw1 + kw2 + kw3 - kw_used}
        end)
      end)
    end)
    |> then(fn %SimState{} = state ->
      secs = state.tick |> div(Ticker.ticks_per_second())
      supplied_kwh = state.supplied_total / secs
      supplied_mwh = supplied_kwh / 1000
      supplied_ratio = supplied_mwh / demand
      assert_in_delta supplied_ratio, 1.0, 0.1, "Supplied: #{supplied_mwh}, demand: #{demand}"
    end)
  end

  defp random_generator_kw(power_level) do
    # Assume 5 MW per power level, plus or minus 1 MW.
    min = power_level * 5000 - 1000
    max = power_level * 5000 + 1000
    Enum.random(min..max) + (:rand.uniform() - 0.5)
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
    API.mock_get("RES_ABSORPTION_CAPACITY_MW", resistors, times: :any)
    unless is_nil(demand), do: API.mock_get("POWER_DEMAND_MW", demand)
  end

  defp turbine_mocks(loops \\ 1..3)

  defp turbine_mocks(loop) when is_integer(loop) do
    API.mock_get("STEAM_GEN_#{loop - 1}_OUTLET", 1000, times: :any)
    API.mock_get("COOLANT_SEC_#{loop - 1}_PRESSURE", 60, times: :any)
  end

  defp turbine_mocks(loops) when is_list(loops), do: loops |> Enum.each(&turbine_mocks/1)
  defp turbine_mocks(_.._//_ = loops), do: loops |> Enum.each(&turbine_mocks/1)
end
