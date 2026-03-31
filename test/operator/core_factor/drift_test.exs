defmodule AutoNuke.Operator.CoreFactor.DriftTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.CoreFactor.Drift

  alias AutoNuke.Test.MockAPI

  describe "new/1" do
    test "creates drift using start time + duration" do
      assert drift =
               Drift.new(
                 # 1+09:02
                 start_time: {1, 9, 2},
                 # 2 hours
                 duration: {2, 0},
                 start_factor: 3.5,
                 end_factor: 4.0
               )

      assert drift.start_time == 1982
      assert drift.end_time == 2102
      assert drift.start_factor == 3.5
      assert drift.end_factor == 4.0
    end

    test "creates drift using start time + end time" do
      assert drift =
               Drift.new(
                 # 1+02:03
                 start_time: {1, 2, 3},
                 # 2+03:04
                 end_time: {2, 3, 4},
                 start_factor: 4.0,
                 end_factor: 4.2
               )

      assert drift.start_time == 1563
      assert drift.end_time == 3064
      assert drift.start_factor == 4.0
      assert drift.end_factor == 4.2
    end

    test "falls back on prior time if day is ambiguous" do
      # Day 5 at 06:00
      MockAPI.mock_get("TIME_STAMP", 7560)

      assert drift =
               Drift.new(
                 # 5+12:34
                 start_time: {12, 34},
                 # 5+15:02
                 end_time: {15, 2},
                 start_factor: 1.2,
                 end_factor: 3.4
               )

      assert drift.start_time == 7954
      assert drift.end_time == 8102
    end

    test "assumes next day if ambiguous time is earlier than prior time" do
      # Day 3 at 20:02
      MockAPI.mock_get("TIME_STAMP", 5522)

      assert drift =
               Drift.new(
                 # 4+04:04
                 start_time: {4, 4},
                 # 5+03:03
                 end_time: {3, 3},
                 start_factor: 1.2,
                 end_factor: 3.4
               )

      assert drift.start_time == 6004
      assert drift.end_time == 7383
    end

    test "handles strings for start time and end time" do
      assert drift =
               Drift.new(
                 # {6, 5, 43}
                 start_time: "6+05:43",
                 # {7, 2, 1}
                 end_time: "02:01",
                 start_factor: 1.2,
                 end_factor: 3.4
               )

      assert drift.start_time == 8983
      assert drift.end_time == 10201
    end

    test "handles relative strings for start time and duration" do
      # Day 10 at 23:59
      MockAPI.mock_get("TIME_STAMP", 15839)

      assert drift =
               Drift.new(
                 # {11, 12, 2}
                 start_time: "12:02",
                 # {11, 13, 3}
                 duration: "1:01",
                 start_factor: 1.2,
                 end_factor: 3.4
               )

      assert drift.start_time == 16562
      assert drift.end_time == 16623
    end

    test "rejects drift that ends before it starts" do
      assert Drift.new(start_time: 1, end_time: 2, start_factor: 3.0, end_factor: 4.0)

      assert_raise RuntimeError, fn ->
        Drift.new(start_time: 2, end_time: 1, start_factor: 3.0, end_factor: 4.0)
      end
    end
  end

  describe "current_value/2" do
    setup do
      [
        drift:
          Drift.new(
            start_time: 10,
            end_time: 15,
            start_factor: 2.0,
            end_factor: 3.0
          )
      ]
    end

    test "returns `:not_started` before start_time", %{drift: drift} do
      assert Drift.current_value(drift, 9) == :not_started
    end

    test "returns `{:complete, end_factor}` at or after end_time", %{drift: drift} do
      assert Drift.current_value(drift, 16) == {:complete, 3.0}
      assert Drift.current_value(drift, 15) == {:complete, 3.0}
    end

    test "returns `{:drifting, target}` while in time window", %{drift: drift} do
      cv = fn time, value ->
        assert {:drifting, target} = Drift.current_value(drift, time)
        assert_in_delta target, value, 0.0001
      end

      cv.(10, 2.0)
      cv.(11, 2.2)
      cv.(12, 2.4)
      cv.(13, 2.6)
      cv.(14, 2.8)
    end

    test "supports drifting downwards as well" do
      assert drift =
               Drift.new(
                 start_time: 10,
                 end_time: 15,
                 start_factor: 3.0,
                 end_factor: 2.0
               )

      cv = fn time, value ->
        assert {:drifting, target} = Drift.current_value(drift, time)
        assert_in_delta target, value, 0.0001
      end

      cv.(10, 3.0)
      cv.(11, 2.8)
      cv.(12, 2.6)
      cv.(13, 2.4)
      cv.(14, 2.2)
      assert {:complete, 2.0} = Drift.current_value(drift, 15)
    end

    test "falls back to current time", %{drift: drift} do
      MockAPI.mock_get("TIME_STAMP", 9)
      assert :not_started = Drift.current_value(drift)

      MockAPI.mock_get("TIME_STAMP", 12)
      assert {:drifting, target} = Drift.current_value(drift)
      assert_in_delta target, 2.4, 0.0001

      MockAPI.mock_get("TIME_STAMP", 15)
      assert {:complete, 3.0} = Drift.current_value(drift)
    end
  end
end
