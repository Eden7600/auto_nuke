defmodule AutoNuke.Operator.SteamFlow.DemandTrackerTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.SteamFlow.DemandTracker, as: DT
  alias AutoNuke.Test.MockAPI, as: API

  describe "new/0" do
    test "assumes we've generated 90% of demand for the current hour (20MW/45min)" do
      API.mock_get("TIME_STAMP", 45)
      API.mock_get("POWER_DEMAND_MW", 20)
      assert %DT{} = dt = DT.new()
      assert dt.demand_kwh == 20000
      assert dt.supplied_kwh == 13500
    end

    test "assumes we've generated 90% of demand for the current hour (35MW/15min)" do
      API.mock_get("TIME_STAMP", 15)
      API.mock_get("POWER_DEMAND_MW", 35)
      assert %DT{} = dt = DT.new()
      assert dt.demand_kwh == 35000
      assert dt.supplied_kwh == 7875
    end

    test "assumes we've generated 90% of demand for the current hour (100MW/0min)" do
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

  describe "target_ratio_range/1" do
    setup do
      create_demand_tracker(minute: 0, demand: 50)
    end

    test "targets between 91% and 109% demand to start", %{dt: dt} do
      assert {0.91, 1.0, 1.09} = DT.target_ratio_range(dt)
    end

    test "broadens target range when supply is meeting demand", %{dt: dt, ts: ts} do
      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 50_000)

      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 50_000)
      assert {min2, 1.0, max2} = DT.target_ratio_range(dt)
      # Should still be broadly similar to the 91% / 109% targets.
      assert_in_delta min2, 0.91, 0.01
      assert_in_delta max2, 1.09, 0.01

      API.mock_get("TIME_STAMP", ts + 2)
      assert dt = DT.tick(dt, 50_000)
      assert {min3, 1.0, max3} = DT.target_ratio_range(dt)
      # Should still be broadly similar to the 91% / 109% targets.
      assert_in_delta min3, 0.91, 0.01
      assert_in_delta max3, 1.09, 0.01

      # Range is broadening.
      assert min3 < min2
      assert max3 > max2
    end

    test "increases target range when supply is not meeting demand", %{dt: dt, ts: ts} do
      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 30_000)
      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 30_000)
      API.mock_get("TIME_STAMP", ts + 2)
      assert dt = DT.tick(dt, 30_000)

      assert {min, tgt, max} = DT.target_ratio_range(dt)
      assert min > 0.92
      assert tgt > 1.01
      assert max > 1.1
    end

    test "decreases target range when supply is exceeding demand", %{dt: dt, ts: ts} do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0, times: :any)

      API.mock_get("TIME_STAMP", ts)
      assert dt = DT.tick(dt, 80_000)
      API.mock_get("TIME_STAMP", ts + 1)
      assert dt = DT.tick(dt, 80_000)
      API.mock_get("TIME_STAMP", ts + 2)
      assert dt = DT.tick(dt, 80_000)

      assert {min, tgt, max} = DT.target_ratio_range(dt)
      assert min < 0.89
      assert tgt < 0.98
      assert max < 1.08
    end

    test "has a minimum range of 0% - 25% when overproducing", %{dt: dt, ts: ts} do
      API.mock_get("RES_ABSORPTION_CAPACITY_MW", 0, times: :any)

      dt =
        0..5
        |> Enum.reduce(dt, fn min, dt ->
          API.mock_get("TIME_STAMP", ts + min)
          DT.tick(dt, 1_210_000)
        end)

      assert {+0.0, +0.0, 0.25} = DT.target_ratio_range(dt)
    end

    test "has a maximum range of 300% and up when underproducing", %{dt: dt, ts: ts} do
      # Jump to the end of the hour:
      API.mock_get("TIME_STAMP", ts + 55)
      assert dt = DT.tick(dt, 1)

      assert {3.0, tgt, max} = DT.target_ratio_range(dt)
      assert tgt > 3.0
      assert max > tgt
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
