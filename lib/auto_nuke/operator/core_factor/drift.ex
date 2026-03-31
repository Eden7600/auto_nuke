defmodule AutoNuke.Operator.CoreFactor.Drift do
  @enforce_keys [:start_time, :end_time, :start_factor, :end_factor]
  defstruct(@enforce_keys)

  alias __MODULE__

  def new(opts) do
    opts = Map.new(opts)
    {start_time, opts} = Map.pop(opts, :start_time, :now)
    start_time = parse_start_time(start_time)
    {end_time, opts} = pop_end_time(opts, start_time)
    {start_factor, opts} = Map.pop!(opts, :start_factor)
    {end_factor, opts} = Map.pop!(opts, :end_factor)
    unless Enum.empty?(opts), do: raise("Unknown Drift options: #{inspect(opts)}")

    drift = %Drift{
      start_time: start_time,
      end_time: end_time,
      start_factor: start_factor,
      end_factor: end_factor
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
      end_time |> parse_time(start_time),
      Map.delete(opts, :end_time)
    }
  end

  defp pop_end_time(%{duration: duration} = opts, start_time) do
    {
      parse_duration(duration, start_time),
      Map.delete(opts, :duration)
    }
  end

  def get_current_time, do: AutoNuke.API.get_integer("TIME_STAMP")

  @minute 1
  @hour 60 * @minute
  @day 24 * @hour
  defp parse_start_time(:now), do: get_current_time()
  defp parse_start_time(t), do: parse_time(t, :now)

  defp parse_time(time, prior_time \\ nil)
  defp parse_time(t, _) when is_integer(t), do: t

  defp parse_time({dd, hh, mm}, _)
       when is_integer(dd) and is_integer(hh) and is_integer(mm),
       do: dd * @day + hh * @hour + mm * @minute

  defp parse_time({hh, mm}, :now)
       when is_integer(hh) and is_integer(mm),
       do: parse_time({hh, mm}, get_current_time())

  defp parse_time({hh, mm}, prior_time)
       when is_integer(hh) and is_integer(mm) and is_integer(prior_time) do
    dd = div(prior_time, @day)

    case parse_time({dd, hh, mm}) do
      ts when ts >= prior_time -> ts
      ts when ts < prior_time -> ts + @day
    end
  end

  @time_regex ~r/^ (?: (\d+) \+ )? (\d{1,2}) : (\d{2}) $/x

  defp parse_time(str, prior_time) when is_binary(str) do
    case Regex.run(@time_regex, str) do
      [_, "", hour, minute] ->
        parse_time({String.to_integer(hour), String.to_integer(minute)}, prior_time)

      [_, day, hour, minute] ->
        parse_time(
          {String.to_integer(day), String.to_integer(hour), String.to_integer(minute)},
          prior_time
        )

      nil ->
        raise "Not a valid time: #{str}"
    end
  end

  defp parse_duration({dd, hh, mm}, start_time)
       when is_integer(dd) and is_integer(hh) and is_integer(mm),
       do: start_time + parse_time({dd, hh, mm}, 0)

  defp parse_duration({hh, mm}, start_time)
       when is_integer(hh) and is_integer(mm),
       do: start_time + parse_time({0, hh, mm}, 0)

  defp parse_duration(mins, start_time) when is_integer(mins),
    do: start_time + mins

  defp parse_duration(str, start_time) when is_binary(str),
    do: start_time + parse_time(str, 0)
end
