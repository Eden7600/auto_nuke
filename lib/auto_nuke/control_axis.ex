defmodule AutoNuke.ControlAxis do
  @enforce_keys [:pidc, :deadzone, :to_value_fn, :last_value]
  defstruct(@enforce_keys)
  alias __MODULE__

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

    %PIDControl{} = pidc = PIDControl.new(kp: kp, kd: kd, ki: ki)
    pidc = %PIDControl{pidc | i: offset}

    %__MODULE__{
      pidc: pidc,
      deadzone: deadzone,
      to_value_fn: wrap_value_fn(t_v_fn),
      last_value: initial
    }
  end

  def step(%ControlAxis{} = axis, target, measurement) do
    measurement = apply_deadzone(axis.deadzone, target, measurement)
    pidc = PIDControl.step(axis.pidc, target, measurement)

    old_value = axis.last_value
    new_value = axis.to_value_fn.(pidc.output, old_value)
    axis = %__MODULE__{axis | pidc: pidc, last_value: new_value}

    if old_value != new_value do
      {:changed, axis, new_value, old_value}
    else
      {:unchanged, axis, old_value}
    end
  end

  def clamp_max(%ControlAxis{pidc: %PIDControl{} = pidc} = axis, max) do
    new_p = min(pidc.p, max)
    new_i = min(pidc.i, max - new_p)
    %ControlAxis{axis | pidc: %PIDControl{pidc | p: new_p, i: new_i}}
  end

  def clamp_min(%ControlAxis{pidc: %PIDControl{} = pidc} = axis, min) do
    new_p = max(pidc.p, min)
    new_i = max(pidc.i, min - new_p)
    %ControlAxis{axis | pidc: %PIDControl{pidc | p: new_p, i: new_i}}
  end

  defp apply_deadzone(+0.0, _target, measurement), do: measurement

  defp apply_deadzone(dz, target, measurement) do
    if abs(target - measurement) <= dz do
      target
    else
      measurement
    end
  end

  # Allow axis_to_value functions to use args (new, old) or just (new).
  defp wrap_value_fn(fun) when is_function(fun, 2), do: fun
  defp wrap_value_fn(fun) when is_function(fun, 1), do: fn v, _ -> fun.(v) end
end
