defmodule AutoNuke.ControlAxisTest do
  use ExUnit.Case

  alias AutoNuke.ControlAxis, as: CA

  test "reports when axis value changes" do
    axis = CA.new(kp: 1)
    assert {:changed, axis, +0.0, nil} = CA.step(axis, 0, 0)
    assert {:unchanged, axis, +0.0} = CA.step(axis, 0, 0)
    assert {:changed, axis, -0.2, +0.0} = CA.step(axis, 0, 0.2)
    assert {:unchanged, _axis, -0.2} = CA.step(axis, 0, 0.2)
  end

  test "uses provided to_value function" do
    axis = CA.new(kp: 1, to_value_fn: fn x -> round(x * 100) end)
    assert {:changed, axis, 0, nil} = CA.step(axis, 0, 0)
    assert {:changed, axis, 20, 0} = CA.step(axis, 0, -0.2)
    assert {:unchanged, axis, 20} = CA.step(axis, 0, -0.2)
    # Output remains unchanged as long as we don't push it to 21.
    assert {:unchanged, _axis, 20} = CA.step(axis, 0, -0.204)
  end

  test "applies offset to values" do
    axis = CA.new(kp: 1, offset: -0.5)
    assert {:changed, axis, -0.5, nil} = CA.step(axis, 0, 0)
    assert {:unchanged, _axis, -0.5} = CA.step(axis, 0, 0)
  end

  test "slews offset downwards when output goes too high" do
    axis = CA.new(kp: 1, offset: 0.9)

    # Would result in adjusted value 1.1, so offset is reduced to 0.8.
    assert {:changed, axis, 1.0, nil} = CA.step(axis, 0, -0.2)
    assert_in_delta axis.offset, 0.8, 0.0001

    # Would result in adjusted value 1.8, so offset is reduced to 0.0.
    assert {:unchanged, axis, 1.0} = CA.step(axis, 0, -100)
    assert_in_delta axis.offset, 0.0, 0.0001
  end

  test "slews offset upwards when output goes too low" do
    axis = CA.new(kp: 1, offset: -0.5)

    # Would result in adjusted value -1.2, so offset is increased to -0.3.
    assert {:changed, axis, -1.0, nil} = CA.step(axis, 0, 0.7)
    assert_in_delta axis.offset, -0.3, 0.0001

    # Would result in adjusted value -1.3, so offset is increased to 0.0.
    assert {:unchanged, axis, -1.0} = CA.step(axis, 0, 100)
    assert_in_delta axis.offset, 0.0, 0.0001
  end

  test "scales offset towards zero when positive offset meets max negative output" do
    axis = CA.new(kp: 1, offset: 0.3)

    assert {:changed, axis, -0.7, nil} = CA.step(axis, 0, 5)
    assert_in_delta axis.offset, 0.285, 0.0001

    assert {:changed, axis, output, -0.7} = CA.step(axis, 0, 5)
    assert_in_delta output, -0.715, 0.0001
    assert_in_delta axis.offset, 0.27075, 0.0001
  end

  test "scales offset towards zero when negative offset meets max positive output" do
    axis = CA.new(kp: 1, offset: -0.8)

    assert {:changed, axis, output1, nil} = CA.step(axis, 0, -5)
    assert_in_delta output1, 0.2, 0.0001
    assert_in_delta axis.offset, -0.76, 0.0001

    assert {:changed, axis, output2, ^output1} = CA.step(axis, 0, -5)
    assert_in_delta output2, 0.24, 0.0001
    assert_in_delta axis.offset, -0.722, 0.0001
  end

  defp settle_loop(_axis, full, full, remaining, overshoots),
    do: {:complete, remaining, overshoots}

  defp settle_loop(_axis, _target, current, 0, _), do: {:failed, current}

  # We're filling a tank that is at `current_fill` and stopping at `target_fill`.
  # When the valve is at setting `open`, we increase it by the square of that open value.
  defp settle_loop(axis, target_fill, current_fill, remaining, overshoots) do
    {open, axis} =
      case CA.step(axis, 1.0, current_fill / target_fill) do
        {:changed, ax, out, _} -> {out, ax}
        {:unchanged, ax, out} -> {out, ax}
      end

    new_fill = current_fill + open * abs(open)

    overshoots =
      overshoots +
        cond do
          current_fill < target_fill and new_fill > target_fill -> 1
          current_fill > target_fill and new_fill < target_fill -> 1
          true -> 0
        end

    settle_loop(axis, target_fill, new_fill, remaining - 1, overshoots)
  end

  test "uses PID controller to settle on value" do
    # With only `kp`, it gets stuck.
    axis = CA.new(kp: 5, to_value_fn: fn x -> round(x * 5) end)
    assert {:failed, 1210} = settle_loop(axis, 1234, 0, 200, 0)

    # With `ki`, it oscillates a bit but completes.
    axis = CA.new(kp: 5, ki: 0.5, to_value_fn: fn x -> round(x * 5) end)
    assert {:complete, 36, 2} = settle_loop(axis, 1234, 0, 200, 0)

    # With both `ki` and `kd`, it only overshoots once, and hits the target much sooner.
    axis = CA.new(kp: 5, kd: 20, ki: 0.5, to_value_fn: fn x -> round(x * 5) end)
    assert {:complete, 97, 1} = settle_loop(axis, 1234, 0, 200, 0)
  end
end
