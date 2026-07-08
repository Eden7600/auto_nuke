defmodule AutoNuke.LogFormatter do
  def format(level, message, timestamp, _metadata) do
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
end
