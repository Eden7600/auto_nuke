defmodule AutoNuke.TaskUI do
  alias IO.ANSI

  @width 60
  def width, do: @width
  @dot "\u2e31"

  def emoji(:warning), do: "\u26a0\ufe0f"
  def emoji(:checkmark), do: "\u2705\ufe0f"
  def emoji(:cross), do: "\u274c\ufe0f"
  def emoji(:right_triangle), do: "\u25b6\ufe0f"
  def emoji(:pointing), do: "\u{1f449}\ufe0f"
  def emoji(:panel), do: "\u{1f39b}\ufe0f"
  def emoji(:spin), do: "\u{1f504}\ufe0f"
  def emoji(:hourglass), do: "\u23f3\ufe0f"
  def emoji(:phone), do: "\u{1f4f2}\ufe0f"

  def console(name), do: IO.puts(["\n", emoji(:panel), " ", String.upcase(name), ":"])
  def tablet(name), do: IO.puts(["\n", emoji(:phone), " ", String.upcase(name), ":"])

  def init do
    Application.put_env(:auto_nuke, :start, false)
    {:ok, _} = Application.ensure_all_started([:auto_nuke, :logger])
  end

  def set(key, value) do
    dot_line(key, value, emoji(:pointing)) |> IO.puts()
  end

  def test(key, fun) do
    dot_line(key, "TESTING", emoji(:pointing))
    |> then(&IO.write(:stdio, &1))

    case rval = fun.() do
      :pass -> ["\r", dot_line(key, "PASS", emoji(:checkmark))] |> IO.puts()
      :fail -> ["\r", dot_line(key, "FAIL", emoji(:cross))] |> IO.puts()
    end

    rval
  end

  def wait(key, value, check) do
    line = dot_line(key, value)
    wait_loop(line, check)
  end

  def set_wait(key, value, check, set) do
    line = dot_line(key, value)
    wait_loop(line, check, set)
  end

  def set_wait_unless(key, value, initial, check, set) do
    line = dot_line(key, value)

    if initial.() do
      IO.puts(["\r", emoji(:checkmark), "  ", line])
    else
      wait_loop(line, check, set)
    end
  end

  defp wait_loop(line, check, set \\ fn -> :noop end) do
    if check.() do
      IO.puts(["\r", emoji(:checkmark), "  ", line])
    else
      IO.write(["\r", emoji(:pointing), "  ", line])
      set.()
      Process.sleep(500)
      wait_loop(line, check)
    end
  end

  defp dot_line(key, value, emoji \\ nil) do
    dot_count = @width - String.length(key) - String.length(value) - 6
    dots = String.duplicate(@dot, max(dot_count, 3))
    line = [key, " ", dots, " ", value]

    case emoji do
      nil -> line
      str when is_binary(str) -> [emoji, "  " | line]
    end
  end

  def warn(msg) do
    IO.puts([
      ANSI.yellow(),
      emoji(:warning),
      " ",
      msg,
      ANSI.reset()
    ])
  end

  def success(msg), do: IO.puts([emoji(:checkmark), "  ", msg])
  def notice(msg), do: IO.puts([emoji(:right_triangle), "  ", msg])

  def log_to_file(file) do
    file = Path.expand(file)

    {:ok, default} = :logger.get_handler_config(:default)
    :logger.remove_handler(:default)

    :logger.add_handler(
      :startup_handler,
      :logger_std_h,
      %{
        config: %{file: String.to_charlist(file)},
        formatter: Map.fetch!(default, :formatter),
        level: Map.fetch!(default, :level)
      }
    )
  end

  def parse_loop("1"), do: 1
  def parse_loop("A"), do: 1
  def parse_loop("a"), do: 1

  def parse_loop("2"), do: 2
  def parse_loop("B"), do: 2
  def parse_loop("b"), do: 2

  def parse_loop("3"), do: 3
  def parse_loop("C"), do: 3
  def parse_loop("c"), do: 3
end
