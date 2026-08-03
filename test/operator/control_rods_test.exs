defmodule AutoNuke.Operator.ControlRodsTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.ControlRods
  alias AutoNuke.Test.MockAPI

  # Callbacks are driven directly in the test process so MockAPI's
  # per-process mocks apply without alias gymnastics.

  @tick AutoNuke.Operator.assigned_tick(ControlRods)

  setup do
    start_supervised!(PubSub)

    # Three installed banks at 40%, six empty slots.
    for bank <- 0..2, do: MockAPI.mock_get("ROD_BANK_POS_#{bank}_ACTUAL", 40.0, times: :any)
    for bank <- 3..8, do: MockAPI.mock_get("ROD_BANK_POS_#{bank}_ACTUAL", "null", times: :any)

    # Boron present -> the high-gain PID profile (worst case for hunting).
    MockAPI.mock_get("CHEM_BORON_PPM", 3000.0, times: :any)

    :ok
  end

  defp init(core_temp, target) do
    set_temp(core_temp, 2)
    {:ok, state} = ControlRods.init({target, :direct})
    state
  end

  defp tick(state) do
    {:noreply, state} = ControlRods.handle_info({:tick, @tick}, state)
    state
  end

  # The verified-read loop consumes exactly ONE reading when the value
  # matches the previous tick's, and TWO when it changed; `times: :any`
  # would shadow later changes, so counts must be exact.
  defp set_temp(temp, reads) do
    MockAPI.mock_get("CORE_TEMP", temp, times: reads)
  end

  defp refute_rod_commands do
    for bank <- 0..2 do
      assert_raise RuntimeError, ~r/not received/, fn ->
        MockAPI.mock_put_value("ROD_BANK_POS_#{bank}_ORDERED")
      end
    end
  end

  test "on-target ticks issue no rod commands" do
    state = init(340.0, 340.0)
    set_temp(340.0, 1)
    state = tick(state)
    set_temp(340.0, 1)
    tick(state)

    refute_rod_commands()
  end

  test "small jitter inside the calm zone is held, not commanded" do
    state = init(340.0, 340.0)
    set_temp(340.0, 1)
    state = tick(state)

    # ±0.1°C of measurement noise — under the old behaviour this issued a
    # fractional rod move every tick.
    set_temp(339.9, 2)
    state = tick(state)
    set_temp(340.1, 2)
    tick(state)

    refute_rod_commands()
  end

  test "a real deviation still commands the rods immediately" do
    state = init(340.0, 340.0)
    set_temp(340.0, 1)
    state = tick(state)

    # 3°C low — far outside the calm zone.
    set_temp(337.0, 2)
    tick(state)

    # A withdrawal order was issued (fewer % than the 40% start):
    assert MockAPI.mock_put_value("ROD_BANK_POS_0_ORDERED") < 40.0
  end

  test "sub-degree target changes are ignored; real ones accepted" do
    state = init(340.0, 340.0)

    {:noreply, state} = ControlRods.handle_info({:core_temp, 340.05}, state)
    assert state.target == 340.0

    {:noreply, state} = ControlRods.handle_info({:core_temp, 340.9}, state)
    assert state.target == 340.0

    {:noreply, state} = ControlRods.handle_info({:core_temp, 341.2}, state)
    assert state.target == 341.2
  end
end
