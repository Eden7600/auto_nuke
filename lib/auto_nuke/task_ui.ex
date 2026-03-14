defmodule AutoNuke.TaskUI do
  alias IO.ANSI

  @width 60

  @warning_emoji "\u26a0\ufe0f"
  @checkmark_emoji "\u2705\ufe0f"
  @right_triangle_emoji "\u25b6\ufe0f"
  @pointing_emoji "\u{1f449}\ufe0f"
  @panel_emoji "\u{1f39b}\ufe0f"
  @spin_emoji "\u{1f504}\ufe0f"
  # @hourglass_emoji "\u23f3\ufe0f"
  @phone_emoji "\u{1f4f2}\ufe0f"

  def console(name), do: IO.puts(["\n", @panel_emoji, " ", String.upcase(name), ":"])
  def tablet(name), do: IO.puts(["\n", @phone_emoji, " ", String.upcase(name), ":"])

  def set(key, value) do
    dot_line(key, value, @pointing_emoji) |> IO.puts()
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
      IO.puts(["\r", @checkmark_emoji, "  ", line])
    else
      wait_loop(line, check, set)
    end
  end

  defp wait_loop(line, check, set \\ fn -> :noop end) do
    if check.() do
      IO.puts(["\r", @checkmark_emoji, "  ", line])
    else
      IO.write(["\r", @pointing_emoji, "  ", line])
      set.()
      Process.sleep(500)
      wait_loop(line, check)
    end
  end

  defp dot_line(key, value, emoji \\ nil) do
    dot_count = @width - String.length(key) - String.length(value) - 6
    dots = String.duplicate(".", max(dot_count, 3))
    line = [key, " ", dots, " ", value]

    case emoji do
      nil -> line
      str when is_binary(str) -> [emoji, "  " | line]
    end
  end

  def warn(msg) do
    IO.puts([
      ANSI.yellow(),
      @warning_emoji,
      " ",
      msg,
      ANSI.reset()
    ])
  end

  def success(msg), do: IO.puts([@checkmark_emoji, "  ", msg])
  def notice(msg), do: IO.puts([@right_triangle_emoji, "  ", msg])

  def progress_loop(opts) do
    fetch = Keyword.fetch!(opts, :fetch)
    max = Keyword.fetch!(opts, :max)
    check = Keyword.get(opts, :check, fn v -> v >= max end)

    label =
      case Keyword.fetch(opts, :label) do
        {:ok, l} -> "#{@spin_emoji}  #{l}"
        :error -> "#{@spin_emoji} "
      end

    format = [
      left: "#{label} [",
      right: "]",
      width: @width - 1,
      percent: false,
      suffix: :count
    ]

    progress_loop_worker(fetch, max, check, format)
  end

  defp progress_loop_worker(fetch, max, check, format) do
    value = fetch.()

    if check.(value) do
      format = Keyword.update!(format, :left, &String.replace(&1, @spin_emoji, @checkmark_emoji))
      ProgressBar.render(min(value, max), max, format)
      :ok
    else
      ProgressBar.render(value, max, format)
      Process.sleep(500)
      progress_loop_worker(fetch, max, check, format)
    end
  end

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
end
