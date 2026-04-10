defmodule AutoNuke.Time do
  def get_current_time, do: AutoNuke.API.Misc.get_time_stamp()

  @minute 1
  @hour 60 * @minute
  @day 24 * @hour

  def parse_time(time, prior_time \\ nil)
  def parse_time(t, _) when is_integer(t), do: t

  def parse_time({dd, hh, mm}, _)
      when is_integer(dd) and is_integer(hh) and is_integer(mm),
      do: dd * @day + hh * @hour + mm * @minute

  def parse_time({hh, mm}, :now)
      when is_integer(hh) and is_integer(mm),
      do: parse_time({hh, mm}, get_current_time())

  def parse_time({hh, mm}, prior_time)
      when is_integer(hh) and is_integer(mm) and is_integer(prior_time) do
    dd = div(prior_time, @day)

    case parse_time({dd, hh, mm}) do
      ts when ts >= prior_time -> ts
      ts when ts < prior_time -> ts + @day
    end
  end

  @time_regex ~r/^ (?: (\d+) \+ )? (\d{1,2}) : (\d{2}) $/x

  def parse_time(str, prior_time) when is_binary(str) do
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

  def parse_duration({dd, hh, mm}, start_time)
      when is_integer(dd) and is_integer(hh) and is_integer(mm),
      do: start_time + parse_time({dd, hh, mm}, 0)

  def parse_duration({hh, mm}, start_time)
      when is_integer(hh) and is_integer(mm),
      do: start_time + parse_time({0, hh, mm}, 0)

  def parse_duration(mins, start_time) when is_integer(mins),
    do: start_time + mins

  def parse_duration(str, start_time) when is_binary(str),
    do: start_time + parse_time(str, 0)

  def timestamp_to_tuple(ts) when is_integer(ts) do
    {dd, ts} = div_rem(ts, @day)
    {hh, mm} = div_rem(ts, @hour)
    {dd, hh, mm}
  end

  def timestamp_to_string(ts) when is_integer(ts) do
    {dd, hh, mm} = timestamp_to_tuple(ts)

    [hh, mm] =
      [hh, mm]
      |> Enum.map(fn n ->
        n
        |> Integer.to_string()
        |> String.pad_leading(2, "0")
      end)

    "#{dd}+#{hh}:#{mm}"
  end

  defp div_rem(a, b), do: {div(a, b), rem(a, b)}
end
