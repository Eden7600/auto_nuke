defmodule AutoNuke.Operator.XenonGuardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AutoNuke.Operator.XenonGuard
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(XenonGuard)

  setup do
    start_supervised!(PubSub)
    MockAPI.mock_get("TIME_STAMP", 100, times: :any)
    :ok
  end

  # Both watch windows must fill before the operator trusts its readings,
  # so warm up with a flat history at the starting levels.
  defp init(xenon, iodine \\ 1.0, rods \\ 50.0) do
    MockAPI.mock_get("CORE_XENON_CUMULATIVE", xenon)
    MockAPI.mock_get("CORE_IODINE_GENERATION", iodine)
    {:ok, state} = XenonGuard.init(nil)

    Enum.reduce(1..30, state, fn _, acc -> tick(acc, xenon, iodine, rods) end)
  end

  defp tick(state, xenon, iodine, rods) do
    MockAPI.mock_get("CORE_XENON_CUMULATIVE", xenon)
    MockAPI.mock_get("CORE_IODINE_GENERATION", iodine)
    MockAPI.mock_get("RODS_POS_ACTUAL", rods)
    {:noreply, state} = XenonGuard.handle_info({:tick, @tick}, state)
    state
  end

  defp refute_put(key) do
    assert_raise RuntimeError, ~r/not received/, fn -> MockAPI.mock_put_value(key) end
  end

  # The guard is a watchdog: it warns on trouble but never commands the
  # plant — riding out a wave is BoronLevel's job.

  test "a quiet plant raises no flags" do
    state = init(15.0, 2.0, 20.0)

    refute state.wave
    refute state.iodine_high
    assert state.next_spiral_alarm == 0
  end

  test "xenon over the ceiling flags a wave and warns" do
    {state, log} =
      with_log(fn -> init(15.0) |> tick(21.0, 1.0, 50.0) end)

    assert state.wave
    assert log =~ "over the 20.0 ceiling"
  end

  test "a wave clears below the hysteresis band" do
    state = init(15.0) |> tick(21.0, 1.0, 50.0)
    assert state.wave

    # Under the ceiling but not yet under @xenon_ok — still the same wave.
    state = tick(state, 17.0, 1.0, 50.0)
    assert state.wave

    # (The all-clear is a notice, which the test log level filters out —
    # the flag is the assertable signal.)
    state = tick(state, 14.0, 1.0, 50.0)
    refute state.wave
  end

  test "high iodine production warns with the scheduled wave's ETA" do
    # TIME_STAMP is 100 game-minutes; the wave lands 6 game-hours later.
    {state, log} = with_log(fn -> init(10.0, 4.0) end)

    assert state.iodine_high
    assert log =~ "Iodine production at 4.0"
    assert log =~ "xenon wave for ~0+07:40"
  end

  test "iodine recovery clears the flag once the average settles" do
    state = init(10.0, 4.0)
    assert state.iodine_high

    # One low tick barely moves a 10-sample average — no flap.
    state = tick(state, 10.0, 1.0, 50.0)
    assert state.iodine_high

    state = Enum.reduce(1..10, state, fn _, acc -> tick(acc, 10.0, 1.0, 50.0) end)

    refute state.iodine_high
  end

  test "the guard never touches banks or steam" do
    state = init(15.0) |> tick(30.0, 5.0, 50.0)

    assert state.wave
    refute_put("RESISTOR_BANKS_MAIN_SWITCH")
    refute_put("STEAM_TURBINE_TRIP")
  end

  # Spiral: no rod travel, no boron reserve, reaction dying, xenon rising.

  test "exhausted reserves with rising xenon fire the spiral alarm" do
    MockAPI.mock_get("CHEM_BORON_PPM", 20.0)
    MockAPI.mock_get("CORE_STATE_CRITICALITY", -0.5)

    {state, log} = with_log(fn -> init(70.0, 1.0, 3.0) |> tick(78.0, 1.0, 3.0) end)

    assert state.next_spiral_alarm > 0
    assert log =~ "XENON SPIRAL"
  end

  test "bottomed rods with boron left is not a spiral" do
    # Boron can still be filtered out — reserve exists, no alarm.
    MockAPI.mock_get("CHEM_BORON_PPM", 1800.0)

    state = init(70.0, 1.0, 3.0) |> tick(78.0, 1.0, 3.0)

    assert state.next_spiral_alarm == 0
  end
end
