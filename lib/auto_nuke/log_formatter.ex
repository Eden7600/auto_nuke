defmodule AutoNuke.LogFormatter do
  # Elixir logger style:
  def format(level, message, timestamp, metadata) do
    do_format(level, message, timestamp, metadata)
  end

  # Erlang logger style, used by TaskUI.log_to_file:
  def format(event, _config) do
    do_format(event.level, message_text(event.msg), event.meta.time, event.meta)
  end

  # Erlang log messages come in three shapes; only the first is already
  # printable. Crash reports are `:report`, and getting this wrong means
  # losing exactly the messages you most need.
  defp message_text({:string, chardata}), do: safe_chardata(chardata)
  defp message_text({:report, report}), do: inspect(report, limit: :infinity)

  defp message_text({format, args}) when is_list(args) do
    :io_lib.format(format, args) |> safe_chardata()
  rescue
    _ -> inspect({format, args})
  end

  defp message_text(other), do: safe_chardata(other)

  defp safe_chardata(message) do
    IO.chardata_to_string(message)
  rescue
    _ -> inspect(message)
  end

  defp do_format(level, message, timestamp, _metadata) do
    try do
      time =
        case AutoNuke.TimeTracker.get() do
          {ts, ticks} -> sim_time(ts, ticks)
          nil -> system_time(timestamp)
        end

      [
        time,
        " [",
        Atom.to_string(level),
        "] ",
        safe_chardata(message),
        "\n"
      ]
    rescue
      # Never write to stdout from here — it would corrupt the TUI.
      e -> "?? [#{level}] unformattable log event: #{Exception.message(e)}\n"
    end
  end

  def sim_time(ts, ticks) do
    [
      AutoNuke.Time.timestamp_to_string(ts),
      ".",
      ticks |> Integer.to_string() |> String.pad_leading(2, "0")
    ]
  end

  def system_time({_date, {hour, minute, second, ms}}) do
    :io_lib.format(
      "~2..0B:~2..0B:~2..0B.~3..0B",
      [hour, minute, second, ms]
    )
  end

  def system_time(time) when is_integer(time) do
    dt = DateTime.from_unix!(time, :microsecond)

    {
      nil,
      {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0) |> div(1000)}
    }
    |> system_time()
  end
end
