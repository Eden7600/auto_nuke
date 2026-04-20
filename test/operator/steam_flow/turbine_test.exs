defmodule AutoNuke.Operator.SteamFlow.TurbineTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.SteamFlow.Turbine
  alias AutoNuke.Test.MockAPI, as: API
  alias AutoNuke.Smoother

  # This seems like a lot of ticks to wait for things to settle,
  # but I'm going to roll with it for now and tune the PID controller
  # in the real game.
  @settle_time 120

  describe "new/2" do
    test "determines power level based on MSCV" do
      API.mock_get("COOLANT_CORE_CIRCULATION_PUMP_2_CAPACITY", 200)
      API.mock_get("COOLANT_SEC_CIRCULATION_PUMP_2_CAPACITY", 200)
      API.mock_get("STEAM_TURBINE_2_BYPASS_ACTUAL", 0, times: 2)
      API.mock_get("MSCV_2_OPENING_ACTUAL", 4)
      API.mock_get("COOLANT_SEC_2_PRESSURE", 60)
      API.mock_get("STEAM_GEN_2_OUTLET", 50)

      assert %Turbine{} = turbine = Turbine.new(3, 50)
      assert turbine.loop == 3
      assert turbine.power_level == 4
      assert turbine.pressure == 60
      assert turbine.steam == 50
    end
  end

  describe "set_min_steam/2" do
    setup do
      [turbine: new_turbine()]
    end

    test "sets minimum steam level", %{turbine: turbine} do
      new_steam = Enum.random(1..50)
      assert %Turbine{} = turbine = Turbine.set_min_steam(turbine, new_steam)
      assert turbine.min_steam == new_steam
    end
  end

  describe "set_power_level/2" do
    setup do
      [turbine: new_turbine(loop: 1)]
    end

    test "sets power level", %{turbine: turbine} do
      API.mock_get("STEAM_TURBINE_0_BYPASS_ACTUAL", 0)
      new_power = Enum.random(2..30)
      assert %Turbine{} = turbine = Turbine.set_power_level(turbine, new_power)
      assert turbine.power_level == new_power
      assert ^new_power = API.mock_put_value("MSCV_0_OPENING_ORDERED")
    end
  end

  describe "max_power_level/1" do
    setup do
      [turbine: new_turbine(loop: 1)]
    end

    test "returns one level higher than current steam output", %{turbine: turbine} do
      API.mock_get("STEAM_GEN_0_OUTLET", 40)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60)
      assert Turbine.max_power_level(turbine) == 5
    end

    test "maxes out at one tenth of the pump capacity", %{turbine: %Turbine{} = turbine} do
      API.mock_get("STEAM_GEN_0_OUTLET", 10000, times: 2)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 60, times: 2)

      turbine = %Turbine{turbine | secondary_capacity: 200}
      assert Turbine.max_power_level(turbine) == 20

      turbine = %Turbine{turbine | secondary_capacity: 300}
      assert Turbine.max_power_level(turbine) == 30
    end

    test "refuses to increase if pressure is too low", %{turbine: turbine} do
      API.mock_get("STEAM_GEN_0_OUTLET", 10000)
      API.mock_get("COOLANT_SEC_0_PRESSURE", 54)
      assert Turbine.max_power_level(turbine) == turbine.power_level
    end
  end

  describe "tick/1 at power level 5" do
    setup do
      [turbine: new_turbine(loop: 1, power_level: 5, min_steam: 25)]
    end

    test "pushes bypass to zero", %{turbine: turbine} do
      final_turbine =
        1..@settle_time
        |> Enum.reduce(turbine, fn _, old_t ->
          API.mock_get("COOLANT_SEC_0_PRESSURE", 50)
          API.mock_get("STEAM_GEN_0_OUTLET", 50)
          assert %Turbine{} = new_t = Turbine.tick(old_t)
          assert new_t.bypass <= old_t.bypass
          new_t
        end)

      assert final_turbine.bypass == 0
    end
  end

  describe "tick/1 at power level 3" do
    setup do
      [turbine: new_turbine(loop: 1, power_level: 3, min_steam: 50)]
    end

    test "ensures enough steam", %{turbine: turbine} do
      # Let's pretend steam is just bypass x2, so our target is 25 bypass = 50 steam.
      steam_fun = fn bypass -> bypass * 2.0 end
      # Steam output will be the average of the last 3 steam readings.
      smoother = Smoother.new(3)

      {final_turbine, _} =
        1..@settle_time
        |> Enum.reduce({turbine, smoother}, fn _, {old_t, smoother} ->
          smoother = Smoother.add(smoother, steam_fun.(old_t.bypass))
          API.mock_get("STEAM_GEN_0_OUTLET", Smoother.average(smoother))
          API.mock_get("COOLANT_SEC_0_PRESSURE", 0)

          assert %Turbine{} = new_t = Turbine.tick(old_t)
          {new_t, smoother}
        end)

      assert final_turbine.bypass == 25
    end

    test "ensures low enough pressure", %{turbine: turbine} do
      # Let's pretend bypass below 40 will cause pressure to rise.
      pressure_fun = fn pressure, bypass -> pressure + (40 - bypass) / 3 end
      # We'll simulate this by taking the average of the last 5 readings,
      # starting with a random pressure between 50 and 70.
      smoother = Smoother.new(5) |> Smoother.add(50 + :rand.uniform() * 20.0)

      {final_turbine, _} =
        1..@settle_time
        |> Enum.reduce({turbine, smoother}, fn _, {old_t, smoother} ->
          new_pressure = Smoother.average(smoother) |> pressure_fun.(old_t.bypass)
          smoother = Smoother.add(smoother, new_pressure)

          API.mock_get("STEAM_GEN_0_OUTLET", 100)
          API.mock_get("COOLANT_SEC_0_PRESSURE", new_pressure)

          assert %Turbine{} = new_t = Turbine.tick(old_t)
          {new_t, smoother}
        end)

      # Sometimes we get 39.
      assert_in_delta final_turbine.bypass, 40, 1
    end
  end

  defp new_turbine(opts \\ []), do: AutoNuke.Test.TurbineFactory.create(opts)
end
