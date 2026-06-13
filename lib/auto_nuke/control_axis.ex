defmodule AutoNuke.ControlAxis do
  @enforce_keys [:pidc, :deadzone, :to_value_fn, :to_value_state, :last_value]
  defstruct(@enforce_keys)
  alias __MODULE__

  def new(opts) do
    {kp, opts} = Keyword.pop!(opts, :kp)
    {kd, opts} = Keyword.pop(opts, :kd, 0)
    {ki, opts} = Keyword.pop(opts, :ki, 0)
    {t_v_fn, opts} = Keyword.pop(opts, :to_value_fn, &Function.identity/1)
    {t_v_state, opts} = Keyword.pop(opts, :to_value_state)
    {offset, opts} = Keyword.pop(opts, :offset, 0.0)
    {deadzone, opts} = Keyword.pop(opts, :deadzone, 0.0)
    {initial, opts} = Keyword.pop(opts, :initial_value, nil)
    {zero_d, opts} = Keyword.pop(opts, :zero_d, true)

    unless Enum.empty?(opts) do
      raise "Unknown options for #{__MODULE__}.new: #{Keyword.keys(opts) |> inspect()}"
    end

    %PIDControl{} =
      pidc =
      PIDControl.new(
        kp: kp,
        kd: kd,
        ki: ki,
        zero_d_on_set_point_change: zero_d
      )

    pidc = %PIDControl{pidc | i: offset}

    %__MODULE__{
      pidc: pidc,
      deadzone: deadzone,
      to_value_fn: wrap_value_fn(t_v_fn),
      to_value_state: t_v_state,
      last_value: initial
    }
  end

  def set_state(%ControlAxis{} = axis, new_state) do
    %ControlAxis{axis | to_value_state: new_state}
  end

  def peek(%ControlAxis{} = axis) do
    {:ok, value, _} = axis.to_value_fn.(axis.pidc.output, axis.to_value_state)
    value
  end

  def step(%ControlAxis{} = axis, target, measurement) do
    pidc = step_with_deadzone(axis.pidc, axis.deadzone, target, measurement)

    old_value = axis.last_value
    old_v_state = axis.to_value_state
    {:ok, new_value, new_v_state} = axis.to_value_fn.(pidc.output, old_v_state)
    axis = %__MODULE__{axis | pidc: pidc, last_value: new_value, to_value_state: new_v_state}

    if old_value != new_value do
      {:changed, axis, new_value, old_value}
    else
      {:unchanged, axis, old_value}
    end
  end

  def clamp_max(%ControlAxis{pidc: %PIDControl{} = pidc} = axis, max, new_value \\ nil) do
    new_p = min(pidc.p, max)
    new_i = min(pidc.i, max - new_p)

    %ControlAxis{
      axis
      | pidc: %PIDControl{pidc | p: new_p, i: new_i},
        last_value: new_value || axis.last_value
    }
  end

  def clamp_min(%ControlAxis{pidc: %PIDControl{} = pidc} = axis, min, new_value \\ nil) do
    new_p = max(pidc.p, min)
    new_i = max(pidc.i, min - new_p)

    %ControlAxis{
      axis
      | pidc: %PIDControl{pidc | p: new_p, i: new_i},
        last_value: new_value || axis.last_value
    }
  end

  defp step_with_deadzone(%PIDControl{} = pidc, +0.0, target, measurement) do
    PIDControl.step(pidc, target, measurement)
  end

  defp step_with_deadzone(%PIDControl{} = pidc, dz, target, measurement) do
    delta = abs(target - measurement)
    dz_ratio = delta / dz

    if dz_ratio < 1.0 do
      old_config = pidc.config
      zero_config = pidc.config |> Map.update!(:ki, &(&1 * dz_ratio))

      pidc
      |> Map.replace!(:config, zero_config)
      |> PIDControl.step(target, measurement)
      |> Map.replace!(:config, old_config)
    else
      PIDControl.step(pidc, target, measurement)
    end
  end

  # Allow axis_to_value functions to use args (new, old) or just (new).
  defp wrap_value_fn(fun) when is_function(fun, 2), do: fun

  defp wrap_value_fn(fun) when is_function(fun, 1) do
    fn value, state -> {:ok, fun.(value), state} end
  end
end
