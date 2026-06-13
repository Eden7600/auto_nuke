defmodule AutoNuke.Operator.CoreFactor.Drift do
  @enforce_keys [:start_time, :end_time, :start_factor, :end_factor, :mode]
  defstruct(@enforce_keys)

  alias __MODULE__
  alias AutoNuke.Time, as: NT

  def new(opts) do
    opts = Map.new(opts)
    {start_time, opts} = Map.pop(opts, :start_time, :now)
    start_time = parse_start_time(start_time)
    {end_time, opts} = pop_end_time(opts, start_time)
    {start_factor, opts} = Map.pop!(opts, :start_factor)
    {end_factor, opts} = Map.pop!(opts, :end_factor)
    {mode, opts} = Map.pop(opts, :mode, :manual)
    unless Enum.empty?(opts), do: raise("Unknown Drift options: #{inspect(opts)}")

    drift = %Drift{
      start_time: start_time,
      end_time: end_time,
      start_factor: start_factor,
      end_factor: end_factor,
      mode: mode
    }

    cond do
      end_time < start_time -> raise "End time is before start time: #{inspect(drift)}"
      true -> drift
    end
  end

  def current_value(drift, time \\ :now)
  def current_value(%Drift{} = drift, :now), do: current_value(drift, get_current_time())
  def current_value(%Drift{start_time: st}, t) when t < st, do: :not_started
  def current_value(%Drift{end_time: et, end_factor: ef}, t) when t >= et, do: {:complete, ef}

  def current_value(%Drift{} = drift, time) do
    span = drift.end_time - drift.start_time
    percent_elapsed = (time - drift.start_time) / span
    factor = drift.end_factor * percent_elapsed + drift.start_factor * (1 - percent_elapsed)

    {:drifting, factor}
  end

  defp pop_end_time(%{end_time: _, duration: _}, _) do
    raise("Cannot specify both end_time and duration")
  end

  defp pop_end_time(%{end_time: end_time} = opts, start_time) do
    {
      end_time |> NT.parse_time(start_time),
      Map.delete(opts, :end_time)
    }
  end

  defp pop_end_time(%{duration: duration} = opts, start_time) do
    {
      NT.parse_duration(duration, start_time),
      Map.delete(opts, :duration)
    }
  end

  def get_current_time, do: AutoNuke.API.Misc.get_time_stamp()

  defp parse_start_time(:now), do: NT.get_current_time()
  defp parse_start_time(t), do: NT.parse_time(t, :now)
end
