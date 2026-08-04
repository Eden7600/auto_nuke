defmodule AutoNuke.ToleranceTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Tolerance

  setup do
    File.mkdir_p!("tmp")
    File.rm(Application.get_env(:auto_nuke, :settings_file))
    :ok
  end

  test "falls back to :normal when not running" do
    assert Tolerance.mode() == :normal
    assert Tolerance.set_mode(:steady) == {:error, :not_running}
    assert Tolerance.deadzone(1.0) == 1.0
    assert Tolerance.hysteresis(0.5) == 0.5
    assert Tolerance.min_power_move() == 2
  end

  test "modes scale the control knobs" do
    start_supervised!(Tolerance)

    :ok = Tolerance.set_mode(:exact)
    assert Tolerance.deadzone(1.0) == 0.25
    assert Tolerance.deadzone({0.2, 0.4}) == {0.05, 0.1}
    assert Tolerance.hysteresis(1.0) == 0.0
    assert Tolerance.min_power_move() == 0

    :ok = Tolerance.set_mode(:steady)
    assert Tolerance.deadzone(1.0) == 2.0
    assert Tolerance.hysteresis(0.5) == 1.0
    assert Tolerance.min_power_move() == 3
  end

  test "cycle walks the modes and the mode persists across restarts" do
    start_supervised!(Tolerance)

    assert {:ok, :steady} = Tolerance.cycle()
    assert {:ok, :exact} = Tolerance.cycle()
    assert {:ok, :normal} = Tolerance.cycle()

    :ok = Tolerance.set_mode(:steady)
    stop_supervised!(Tolerance)
    start_supervised!(Tolerance)
    assert Tolerance.mode() == :steady
  end
end
