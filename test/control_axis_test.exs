defmodule AutoNuke.ControlAxisTest do
  use ExUnit.Case, async: true

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

  test "reduces integral change while in deadzone" do
    axis = CA.new(kp: 1, ki: 0.1, deadzone: 0.1)

    # Normal PI control:
    assert {:changed, axis, out1, nil} = CA.step(axis, 0, 0.2)
    assert_in_delta out1, -0.22, 0.00001
    assert_in_delta axis.pidc.i, -0.02, 0.000001

    # Now in deadzone:
    assert {:changed, axis, out2, ^out1} = CA.step(axis, 0.199, 0.2)
    assert_in_delta out2, -0.021001, 0.000001
    assert_in_delta axis.pidc.i, -0.020001, 0.000001

    # Reduced change due to scaled integral:
    assert {:changed, axis, _, _} = CA.step(axis, 0.199, 0.2)
    assert_in_delta axis.pidc.i, -0.020002, 0.000001
    assert {:changed, axis, _, _} = CA.step(axis, 0.199, 0.2)
    assert_in_delta axis.pidc.i, -0.020003, 0.000001

    # But proportional still reacts:
    assert {:changed, _, out4, out3} = CA.step(axis, 0.201, 0.2)
    assert_in_delta out3, -0.021, 0.001
    assert_in_delta out4, -0.019, 0.001
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

  @tag :skip
  test "clamp/2 clamps controller to upper bound" do
    axis = CA.new(kp: 1, ki: 0.1, to_value_fn: fn x -> round(x * 100) end)

    assert {:changed, axis, 22, nil} = CA.step(axis, 0, -0.2)

    # Unclamped:
    assert {:changed, _, 24, 22} = axis |> CA.step(0, -0.2)
    # Clamped to +0.40 (no effect):
    assert {:changed, _, 24, 22} = axis |> CA.clamp(0.4) |> CA.step(0, -0.2)
    # Clamped to +0.20:
    assert {:unchanged, _, 22} = axis |> CA.clamp(0.2) |> CA.step(0, -0.2)
    # Clamped to +0.05: Unchanged, because the 20 is from proportional, 
    # while the 2 is from integral, and all we're doing is clearing the integral.
    assert {:unchanged, _, 22} = axis |> CA.clamp(0.05) |> CA.step(0, -0.2)
    # Clamped to +0.21: This just reduces integral from 0.02 to 0.01.
    assert {:changed, _, 23, 22} = axis |> CA.clamp(0.21) |> CA.step(0, -0.2)
  end

  @tag :skip
  test "clamp/2 clamps controller to lower bound" do
    axis = CA.new(kp: 1, ki: 0.5, to_value_fn: fn x -> round(x * 100) end)

    assert {:changed, axis, -60, nil} = CA.step(axis, 0, 0.4)

    # Unclamped:
    assert {:changed, _, -80, -60} = axis |> CA.step(0, 0.4)
    # Clamped to -0.90 (no effect):
    assert {:changed, _, -80, -60} = axis |> CA.clamp(-0.9) |> CA.step(0, 0.4)
    # Clamped to -0.40:
    assert {:unchanged, _, -60} = axis |> CA.clamp(-0.4) |> CA.step(0, 0.4)
    # Clamped to -0.25: Unchanged — see clamp explanation.
    assert {:unchanged, _, -60} = axis |> CA.clamp(-0.25) |> CA.step(0, 0.4)
    # Clamped to -0.45: Reduces integral from -0.2 to -0.25.
    assert {:changed, _, -65, -60} = axis |> CA.clamp(-0.45) |> CA.step(0, 0.4)
  end

  @tag :skip
  test "clamping improves responsiveness to direction reversals" do
    axis = CA.new(kp: 1, ki: 0.1, to_value_fn: fn x -> round(x * 100) end)

    {clamped, unclamped} =
      1..10
      |> Enum.reduce({axis, axis}, fn _, {old_c, old_u} ->
        new_c = old_c |> CA.step(0, -0.4) |> elem(1) |> CA.clamp(0.5)
        new_u = old_u |> CA.step(0, -0.4) |> elem(1)
        {new_c, new_u}
      end)

    # Unclamped has significant upwards windup, is slow to decrease:
    assert {:changed, _, 7, 80} = unclamped |> CA.step(0, 0.3)
    # Clamped never went much higher than 0.5, so it goes negative immediately:
    assert {:changed, _, -23, 54} = clamped |> CA.step(0, 0.3)

    {clamped, unclamped} =
      1..10
      |> Enum.reduce({axis, axis}, fn _, {old_c, old_u} ->
        new_c = old_c |> CA.step(0, 0.6) |> elem(1) |> CA.clamp(-0.2)
        new_u = old_u |> CA.step(0, 0.6) |> elem(1)
        {new_c, new_u}
      end)

    # Unclamped has bottomed out at -100, is slow to increase:
    assert {:changed, _, -27, -100} = unclamped |> CA.step(0, -0.3)
    # Clamped stopped decreasing, flips quickly:
    assert {:changed, _, 33, -66} = clamped |> CA.step(0, -0.3)
  end
end
