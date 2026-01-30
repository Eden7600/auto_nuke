defmodule AutoNuke.ControlAxis do
  @enforce_keys [:pidc, :offset, :deadzone, :to_value_fn, :last_value]
  defstruct(@enforce_keys)

  def new(opts) do
    {kp, opts} = Keyword.pop!(opts, :kp)
    {kd, opts} = Keyword.pop(opts, :kd, 0)
    {ki, opts} = Keyword.pop(opts, :ki, 0)
    {t_v_fn, opts} = Keyword.pop(opts, :to_value_fn, &Function.identity/1)
    {offset, opts} = Keyword.pop(opts, :offset, 0.0)
    {deadzone, opts} = Keyword.pop(opts, :deadzone, 0.0)
    {initial, opts} = Keyword.pop(opts, :initial_value, nil)

    unless Enum.empty?(opts) do
      raise "Unknown options for #{__MODULE__}.new: #{Keyword.keys(opts) |> inspect()}"
    end

    %__MODULE__{
      pidc: PIDControl.new(kp: kp, kd: kd, ki: ki),
      offset: offset,
      deadzone: deadzone,
      to_value_fn: t_v_fn,
      last_value: initial
    }
  end

  def step(axis, target, measurement) do
    measurement = apply_deadzone(axis.deadzone, target, measurement)
    pidc = PIDControl.step(axis.pidc, target, measurement)
    {output, offset} = adjusted_output(pidc.output, axis.offset)

    old_value = axis.last_value
    new_value = axis.to_value_fn.(output)
    axis = %__MODULE__{axis | pidc: pidc, offset: offset, last_value: new_value}

    if old_value != new_value do
      {:changed, axis, new_value, old_value}
    else
      {:unchanged, axis, old_value}
    end
  end

  defp adjusted_output(output, offset) do
    adjusted = output + offset

    cond do
      adjusted > 1.0 -> {1.0, offset - (adjusted - 1.0)}
      adjusted < -1.0 -> {-1.0, offset - (adjusted + 1.0)}
      true -> {adjusted, offset}
    end
  end

  defp apply_deadzone(+0.0, _target, measurement), do: measurement

  defp apply_deadzone(dz, target, measurement) do
    if abs(target - measurement) <= dz do
      target
    else
      measurement
    end
  end
end
