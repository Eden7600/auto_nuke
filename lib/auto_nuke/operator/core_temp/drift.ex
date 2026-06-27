defmodule AutoNuke.Operator.CoreTemp.Drift do
  @enforce_keys [:start_time, :end_time, :start_temp, :end_temp]
  defstruct(@enforce_keys)

  alias __MODULE__
  alias AutoNuke.Time, as: ANTime

  def new(opts) do
    opts = Map.new(opts)
    {start_time, opts} = Map.pop(opts, :start_time, :now)
    start_time = parse_start_time(start_time)
    {end_time, opts} = pop_end_time(opts, start_time)
    {start_temp, opts} = Map.pop(opts, :start_temp, :current)
    {end_temp, opts} = Map.pop!(opts, :end_temp)
    unless Enum.empty?(opts), do: raise("Unknown Drift options: #{inspect(opts)}")

    drift = %Drift{
      start_time: start_time,
      end_time: end_time,
      start_temp: start_temp + 0.0,
      end_temp: end_temp + 0.0
    }

    cond do
      end_time < start_time -> raise "End time is before start time: #{inspect(drift)}"
      true -> drift
    end
  end

  def describe(%Drift{
        start_time: start_time,
        end_time: end_time,
        start_temp: start_temp,
        end_temp: end_temp
      }) do
    Enum.join([
      case start_temp do
        :current -> ""
        n when is_number(n) -> "from #{n}°C "
      end,
      "at ",
      ANTime.timestamp_to_string(start_time),
      " to #{end_temp}°C at ",
      ANTime.timestamp_to_string(end_time)
    ])
  end

  def current_value(drift, time \\ :now)
  def current_value(%Drift{start_temp: :current}, _), do: {:drifting, :current}
  def current_value(%Drift{} = drift, :now), do: current_value(drift, get_current_time())
  def current_value(%Drift{start_time: st}, t) when t < st, do: :not_started
  def current_value(%Drift{end_time: et, end_temp: temp}, t) when t >= et, do: {:complete, temp}

  def current_value(%Drift{} = drift, time) do
    span = drift.end_time - drift.start_time
    percent_elapsed = (time - drift.start_time) / span
    temp = drift.end_temp * percent_elapsed + drift.start_temp * (1 - percent_elapsed)

    {:drifting, temp}
  end

  defp pop_end_time(%{end_time: _, duration: _}, _) do
    raise("Cannot specify both end_time and duration")
  end

  defp pop_end_time(%{end_time: end_time} = opts, start_time) do
    {
      end_time |> ANTime.parse_time(start_time),
      Map.delete(opts, :end_time)
    }
  end

  defp pop_end_time(%{duration: duration} = opts, start_time) do
    {
      ANTime.parse_duration(duration, start_time),
      Map.delete(opts, :duration)
    }
  end

  def get_current_time, do: ANTime.get_current_time()

  defp parse_start_time(:now), do: ANTime.get_current_time()
  defp parse_start_time(t), do: ANTime.parse_time(t, :now)
end
