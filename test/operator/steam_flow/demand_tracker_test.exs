defmodule AutoNuke.Operator.SteamFlow.DemandTrackerTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.SteamFlow.DemandTracker, as: DT
  alias AutoNuke.Test.MockAPI, as: API

  describe "new/0" do
    test "assumes we've generated 100% of demand for the current hour (20MW/45min)" do
      API.mock_get("TIME_STAMP", 45)
      API.mock_get("POWER_DEMAND_MW", 20)
      assert %DT{} = dt = DT.new()
      assert dt.demand_kwh == 20000
      assert dt.supplied_kwh == 15000
    end

    test "assumes we've generated 100% of demand for the current hour (35MW/15min)" do
      API.mock_get("TIME_STAMP", 15)
      API.mock_get("POWER_DEMAND_MW", 35)
      assert %DT{} = dt = DT.new()
      assert dt.demand_kwh == 35000
      assert dt.supplied_kwh == 8750
    end

    test "assumes we've generated 10% of demand for the current hour (100MW/0min)" do
      API.mock_get("TIME_STAMP", 60)
      API.mock_get("POWER_DEMAND_MW", 100)
      assert %DT{} = dt = DT.new()
      assert dt.demand_kwh == 100_000
      assert dt.supplied_kwh == 0
    end
  end

  describe "tick/2 for a given minute" do
    setup do
      create_demand_tracker(minute: 0, demand: 60)
    end

    test "adds given power supply to tally", %{dt: dt, ts: ts} do
      assert dt.supply_per_second.size == 0

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 10)
      assert dt.supply_per_second.size == 1

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 11)
      assert dt.supply_per_second.size == 2

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 9)
      assert dt.supply_per_second.size == 3
    end

    test "adds average of tally to supply when minute ticks over", %{dt: dt, ts: ts} do
      # Four ticks in one minute:
      API.mock_get("TIME_STAMP", ts, times: 4)
      assert dt = DT.tick(dt, 5_000)
      assert dt = DT.tick(dt, 10_000)
      assert dt = DT.tick(dt, 20_100)
      assert dt = DT.tick(dt, 4_900)

      assert dt.supply_per_second.size == 4

      # Fifth and final tick, because now we're on to the next minute:
      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 35_000)

      # Average is 15 MW, 1/60th of which is 250 kWh.
      assert dt.supplied_kwh == 250.0
      # Tally has been cleared:
      assert dt.supply_per_second.size == 0
    end

    test "deducts resistor banks when overproducing", %{dt: dt, ts: ts} do
      API.mock_get("TIME_STAMP", ts + 1, times: :any)

      # No resistors:
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0)
      assert dt1 = DT.tick(dt, 120_000)
      assert dt1.supplied_kwh == 2000

      # With resistors:
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 100)
      assert dt2 = DT.tick(dt, 120_000)
      assert dt2.supplied_kwh == 1000

      # Exceeding resistors:
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 30)
      assert dt3 = DT.tick(dt, 120_000)
      assert dt3.supplied_kwh == 1500
    end
  end

  describe "tick/2 when hour rolls over" do
    setup do
      create_demand_tracker(minute: Enum.random(5..55))
    end

    test "resets data and retrieves current demand", %{dt: dt, ts: ts} do
      assert dt.supplied_kwh > 0.0

      API.mock_get("TIME_STAMP", ts + 60)
      API.mock_get("POWER_DEMAND_MW", 123.4)
      assert dt = DT.tick(dt, 1_000)
      assert dt.demand_kwh == 123_400
      assert dt.supplied_kwh == 0
      # Current supply is not counted towards tally:
      assert dt.supply_per_second.size == 0
    end
  end

  describe "target_and_deadzone/1" do
    setup do
      create_demand_tracker(minute: 0, demand: 50)
    end

    test "targets between 100% and 110% demand to start", %{dt: dt} do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0)
      assert {1.05, dz} = DT.target_and_deadzone(dt)
      assert_in_delta dz, 0.05, 0.0001
    end

    test "broadens deadzone when supply is meeting demand", %{dt: dt, ts: ts} do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0, times: :any)

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 50_000 * 1.05)
      assert {tgt1, dz1} = DT.target_and_deadzone(dt)
      assert_in_delta tgt1, 1.05, 0.0001
      assert_in_delta dz1, 0.05, 0.0001

      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 50_000 * 1.05)
      assert {tgt2, dz2} = DT.target_and_deadzone(dt)
      assert_in_delta tgt2, 1.05, 0.0001
      assert_in_delta dz2, 0.0508, 0.0001

      API.mock_get("TIME_STAMP", ts + 2)
      assert dt = DT.tick(dt, 50_000 * 1.05)
      assert {tgt3, dz3} = DT.target_and_deadzone(dt)
      assert_in_delta tgt3, 1.05, 0.0001
      assert_in_delta dz3, 0.0517, 0.0001
    end

    test "increases target when supply is not meeting demand", %{dt: dt, ts: ts} do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0, times: :any)

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 10_000)
      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 10_000)
      API.mock_get("TIME_STAMP", ts + 2)
      assert dt = DT.tick(dt, 10_000)

      assert {tgt, _dz} = DT.target_and_deadzone(dt)
      assert_in_delta tgt, 1.08, 0.01
    end

    test "does not increase target beyond 102% when resistors active", %{dt: dt, ts: ts} do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 1, times: :any)

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 1_000)
      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 1_000)
      API.mock_get("TIME_STAMP", ts + 2)
      assert dt = DT.tick(dt, 1_000)

      assert {1.02, _dz} = DT.target_and_deadzone(dt)
    end

    test "decreases target when supply is exceeding demand", %{dt: dt, ts: ts} do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0, times: :any)

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 80_000)
      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 80_000)
      API.mock_get("TIME_STAMP", ts + 2)
      assert dt = DT.tick(dt, 80_000)

      assert {tgt, _dz} = DT.target_and_deadzone(dt)
      assert_in_delta tgt, 1.03, 0.01
    end

    test "exactly meeting 105% demand keeps target the same for the whole hour", %{
      dt: dt,
      ts: ts
    } do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0, times: :any)

      0..59
      |> Enum.reduce(dt, fn n, dt ->
        API.mock_get("TIME_STAMP", ts + n)
        assert dt = DT.tick(dt, 50_000 * 1.05)
        assert {tgt, _} = t = DT.target_and_deadzone(dt)
        assert_in_delta tgt, 1.05, 0.01, "Target begins deviating at minute #{n}: #{inspect(t)}"
        dt
      end)
    end
  end

  defp create_demand_tracker(opts) do
    {hour, opts} = Keyword.pop(opts, :hour, Enum.random(9..100))
    {minute, opts} = Keyword.pop(opts, :minute, Enum.random(0..59))
    {demand, opts} = Keyword.pop(opts, :demand, (10 + :rand.uniform() * 490) |> Float.round(1))
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    timestamp = hour * 60 + minute
    API.mock_get("TIME_STAMP", timestamp)
    API.mock_get("POWER_DEMAND_MW", demand)
    dt = DT.new()

    [dt: dt, ts: timestamp]
  end
end
