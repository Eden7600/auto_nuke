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
      [turbine: new_turbine()]
    end

    test "sets power level", %{turbine: turbine} do
      new_power = Enum.random(1..100)
      assert %Turbine{} = turbine = Turbine.set_power_level(turbine, new_power)
      assert turbine.power_level == new_power
    end
  end

  describe "tick/1 at power level 5" do
    setup do
      [turbine: new_turbine(loop: 1, power_level: 5)]
    end

    test "pushes bypass to zero", %{turbine: turbine} do
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

  describe "tick/1 at power level 3" do
    setup do
      [turbine: new_turbine(loop: 1, power_level: 3, min_steam: 50)]
    end

    test "ensures enough steam", %{turbine: turbine} do
      # Let's pretend steam is just bypass x2, so our target is 25 bypass = 50 steam.
      steam_fun = fn bypass -> bypass * 2.0 end
      # Steam output will be the average of the last 5 steam readings.
      smoother = Smoother.new(5)

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
      pressure_fun = fn pressure, bypass -> pressure + (40 - bypass) / 5 end
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

      assert final_turbine.bypass == 40
    end
  end

  describe "tick/1 at power level 1" do
    setup do
      [turbine: new_turbine(loop: 2, power_level: 1)]
    end

    test "targets 2.5 torque", %{turbine: turbine} do
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

  defp new_turbine(opts \\ []) do
    {loop, opts} = maybe_random(opts, :loop, 1..3)
    {power_level, opts} = maybe_random(opts, :power_level, 0..100)
    {min_steam, opts} = maybe_random(opts, :min_steam, 1..100)
    {bypass, opts} = maybe_random(opts, :bypass, 0..100)
    {torque, opts} = maybe_random(opts, :torque, fn -> random_torque(power_level) end)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    mscv =
      if power_level in 1..2 do
        API.mock_get("STEAM_TURBINE_#{loop - 1}_TORQUE", torque)
        2
      else
        power_level
      end

    API.mock_get("MSCV_#{loop - 1}_OPENING_ACTUAL", mscv)
    API.mock_get("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL", bypass)
    assert %Turbine{} = turbine = Turbine.new(loop, min_steam)
    assert [] = API.unused_mocks()
    turbine
  end

  defp maybe_random(opts, key, _.._//_ = range) do
    maybe_random(opts, key, fn -> Enum.random(range) end)
  end

  defp maybe_random(opts, key, fun) when is_function(fun) do
    Keyword.pop_lazy(opts, key, fun)
  end

  defp random_torque(1), do: 2.000 + :rand.uniform() * 0.699
  defp random_torque(_), do: 2.701 + :rand.uniform() * 5
end
