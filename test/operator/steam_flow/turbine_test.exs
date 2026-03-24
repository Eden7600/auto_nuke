defmodule AutoNuke.Operator.SteamFlow.TurbineTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.SteamFlow.Turbine
  alias AutoNuke.Test.MockAPI, as: API
  alias AutoNuke.Smoother

  # This seems like a lot of ticks to wait for things to settle,
  # but I'm going to roll with it for now and tune the PID controller
  # in the real game.
  @settle_time 100

  describe "new/2" do
    test "determines power level based on MSCV" do
      API.mock_get("STEAM_TURBINE_2_BYPASS_ACTUAL", 0)
      API.mock_get("MSCV_2_OPENING_ACTUAL", 4)

      assert %Turbine{} = turbine = Turbine.new(3, 50)
      assert turbine.loop == 3
      assert turbine.power_level == 4
    end

    test "guesses power level 1 or 2 based on torque" do
      API.mock_get("STEAM_TURBINE_1_BYPASS_ACTUAL", 0)
      API.mock_get("MSCV_1_OPENING_ACTUAL", 2)
      API.mock_get("STEAM_TURBINE_1_TORQUE", 2.5)

      assert %Turbine{} = turbine1 = Turbine.new(2, 50)
      assert turbine1.loop == 2
      assert turbine1.power_level == 1

      API.mock_get("STEAM_TURBINE_0_BYPASS_ACTUAL", 0)
      API.mock_get("MSCV_0_OPENING_ACTUAL", 2)
      API.mock_get("STEAM_TURBINE_0_TORQUE", "3.5")

      assert %Turbine{} = turbine2 = Turbine.new(1, 50)
      assert turbine2.loop == 1
      assert turbine2.power_level == 2
    end
  end

  describe "power level 5" do
    test "pushes bypass to zero" do
      API.mock_get("STEAM_TURBINE_2_BYPASS_ACTUAL", 42)
      API.mock_get("MSCV_2_OPENING_ACTUAL", 5)

      assert %Turbine{} = turbine = Turbine.new(3, 50)
      assert turbine.power_level == 5
      assert turbine.bypass == 42

      final_turbine =
        1..@settle_time
        |> Enum.reduce(turbine, fn _, old_t ->
          assert %Turbine{} = new_t = Turbine.tick(old_t)
          assert new_t.bypass <= old_t.bypass
          new_t
        end)

      assert final_turbine.bypass == 0
    end
  end

  describe "power level 3" do
    test "ensures enough steam" do
      API.mock_get("STEAM_TURBINE_0_BYPASS_ACTUAL", Enum.random(0..100))
      API.mock_get("MSCV_0_OPENING_ACTUAL", 3)

      assert %Turbine{} = turbine = Turbine.new(1, 50)
      assert turbine.power_level == 3

      # Steam output will be the average of the last 5 bypass settings, doubled.
      # Our target will be 25 bypass = 50 steam.
      smoother = Smoother.new(5)

      {final_turbine, _} =
        1..@settle_time
        |> Enum.reduce({turbine, smoother}, fn _, {old_t, smoother} ->
          smoother = Smoother.add(smoother, old_t.bypass * 2.0)
          API.mock_get("STEAM_GEN_0_OUTLET", Smoother.average(smoother) |> Float.to_string())
          API.mock_get("COOLANT_SEC_0_PRESSURE", 0)

          assert %Turbine{} = new_t = Turbine.tick(old_t)
          {new_t, smoother}
        end)

      assert final_turbine.bypass == 25
    end

    test "ensures low enough pressure" do
      API.mock_get("STEAM_TURBINE_0_BYPASS_ACTUAL", Enum.random(0..100))
      API.mock_get("MSCV_0_OPENING_ACTUAL", 3)

      assert %Turbine{} = turbine = Turbine.new(1, 1)
      assert turbine.power_level == 3

      # Bypass settings below 40 will cause pressure to skyrocket.
      # We'll simulate this by taking the average of the last 5 readings.
      smoother = Smoother.new(5) |> Smoother.add(70.0)

      {final_turbine, _} =
        1..@settle_time
        |> Enum.reduce({turbine, smoother}, fn _, {old_t, smoother} ->
          old_pressure = Smoother.average(smoother)
          new_pressure = old_pressure + (40 - old_t.bypass) / 5
          smoother = Smoother.add(smoother, new_pressure)

          API.mock_get("STEAM_GEN_0_OUTLET", 100)
          API.mock_get("COOLANT_SEC_0_PRESSURE", new_pressure)

          assert %Turbine{} = new_t = Turbine.tick(old_t)
          {new_t, smoother}
        end)

      assert final_turbine.bypass == 40
    end
  end

  describe "power level 1" do
    test "targets 2.5 torque" do
      API.mock_get("STEAM_TURBINE_1_BYPASS_ACTUAL", Enum.random(0..100))
      API.mock_get("MSCV_1_OPENING_ACTUAL", 2)
      API.mock_get("STEAM_TURBINE_1_TORQUE", 2.2)

      # min_steam is ignored
      assert %Turbine{} = turbine = Turbine.new(2, 1000)
      assert turbine.power_level == 1

      # Torque will be 2.5 when at 50 bypass, averaged over the last 5 readings.
      # Higher bypass will lead to lower torque and vice versa.
      smoother = Smoother.new(5)

      {final_turbine, _} =
        1..@settle_time
        |> Enum.reduce({turbine, smoother}, fn _, {old_t, smoother} ->
          new_torque = 2.5 - (old_t.bypass - 50) / 50
          smoother = Smoother.add(smoother, new_torque)

          API.mock_get("STEAM_TURBINE_1_TORQUE", new_torque)

          assert %Turbine{} = new_t = Turbine.tick(old_t)
          {new_t, smoother}
        end)

      assert final_turbine.bypass == 50
    end
  end
end
