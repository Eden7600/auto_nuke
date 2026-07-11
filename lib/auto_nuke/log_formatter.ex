defmodule AutoNuke.LogFormatter do
  # Elixir logger style:
  def format(level, message, timestamp, metadata) do
    do_format(level, message, timestamp, metadata)
  end

  # Erlang logger style, used by TaskUI.log_to_file:
  def format(event, _config) do
    level = event.level

    message =
      case event.msg do
        {_, msg} -> msg
        msg -> msg
      end

    timestamp = event.meta.time
    metadata = event.meta

    do_format(level, message, timestamp, metadata)
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
        IO.chardata_to_string(message),
        "\n"
      ]
    rescue
      e -> IO.inspect(e)
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
