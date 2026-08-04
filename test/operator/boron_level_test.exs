defmodule AutoNuke.Operator.BoronLevelTest do
  use ExUnit.Case, async: true

  alias AutoNuke.Operator.BoronLevel

  # The boron-heavy strategy: dose whenever rods sit further in than the
  # ~25% target, filter only when a wave has pushed them under the 10%
  # reserve line, touch nothing in between.

  describe "dosing_rate_for/2" do
    test "quiet at or below the rod target" do
      assert BoronLevel.dosing_rate_for(25.0, 0.0) == 0
      assert BoronLevel.dosing_rate_for(20.0, 0.0) == 0
      assert BoronLevel.dosing_rate_for(10.0, 0.0) == 0
    end

    test "climbs from gentle near the target to full rate at 100%" do
      assert BoronLevel.dosing_rate_for(30.0, 0.0) == 1
      assert BoronLevel.dosing_rate_for(66.0, 0.0) == 15
      assert BoronLevel.dosing_rate_for(100.0, 0.0) == 50
    end

    test "throttles to the remaining headroom below 3500 ppm" do
      assert BoronLevel.dosing_rate_for(100.0, 3490.0) == 10
      assert BoronLevel.dosing_rate_for(100.0, 3500.0) == 0
      # Overshot ppm never yields a negative rate.
      assert BoronLevel.dosing_rate_for(100.0, 3600.0) == 0
    end
  end

  describe "filter_rate_for/2" do
    test "quiet at or above the reserve line" do
      assert BoronLevel.filter_rate_for(10.0, 2000.0) == 0
      assert BoronLevel.filter_rate_for(25.0, 2000.0) == 0
      assert BoronLevel.filter_rate_for(50.0, 2000.0) == 0
    end

    test "climbs from gentle under the line to full speed at 0% rods" do
      assert BoronLevel.filter_rate_for(8.0, 2000.0) == 5
      assert BoronLevel.filter_rate_for(5.0, 2000.0) == 25
      assert BoronLevel.filter_rate_for(0.0, 2000.0) == 100
    end

    test "throttles back as boron runs out" do
      assert BoronLevel.filter_rate_for(0.0, 40.2) == 40
      assert BoronLevel.filter_rate_for(0.0, 0.0) == 0
    end
  end
end
