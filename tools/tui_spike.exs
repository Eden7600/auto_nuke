# Spike: verify raw-mode keyboard input + ANSI rendering work on this platform.
#
# Run with:  mix run tools/tui_spike.exs
#
# Expected: alternate screen opens with a bordered box, keys you press are
# named live (arrows, letters, etc.), and `q` exits cleanly back to your
# prompt with the screen restored.

defmodule TuiSpike do
  @esc "\e"

  def run do
    case start_raw() do
      :ok ->
        enter_screen()

        try do
          loop("(none yet)", 0)
        after
          leave_screen()
        end

        IO.puts("Raw mode worked. Terminal restored. ✅")

      {:error, reason} ->
        IO.puts("Cannot enter raw mode: #{inspect(reason)}")
        IO.puts("(This is expected when stdin is not an interactive terminal.)")
    end
  end

  defp start_raw do
    try do
      case :shell.start_interactive({:noshell, :raw}) do
        :ok -> check_tty()
        {:error, :already_started} -> check_tty()
        {:error, reason} -> {:error, reason}
      end
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  # start_interactive can "succeed" without a usable tty; probe geometry.
  defp check_tty do
    case {:io.columns(), :io.rows()} do
      {{:ok, _}, {:ok, _}} -> :ok
      _ -> {:error, :not_a_tty}
    end
  end

  defp enter_screen do
    # Alt screen, hide cursor.
    IO.write([@esc, "[?1049h", @esc, "[?25l"])
  end

  defp leave_screen do
    # Show cursor, leave alt screen, back to cooked mode.
    IO.write([@esc, "[?25h", @esc, "[?1049l"])
    :shell.start_interactive({:noshell, :cooked})
  end

  defp loop(last_key, count) do
    draw(last_key, count)

    case read_key() do
      "q" -> :ok
      key -> loop(key, count + 1)
    end
  end

  defp draw(last_key, count) do
    {:ok, cols} = :io.columns()
    {:ok, rows} = :io.rows()

    frame = [
      # Home cursor; no full clear per frame (avoids flicker).
      [@esc, "[H"],
      line("┌", "─", "┐", 40),
      row("AutoNuke TUI spike"),
      row("Terminal: #{cols}x#{rows}"),
      row(""),
      row("Last key: #{last_key}"),
      row("Keys pressed: #{count}"),
      row(""),
      row("Try arrows, letters... q to quit"),
      line("└", "─", "┘", 40)
    ]

    IO.write(frame)
  end

  defp line(l, fill, r, w), do: [l, String.duplicate(fill, w - 2), r, @esc, "[K\r\n"]

  defp row(text) do
    text = String.slice(text, 0, 36)
    pad = 38 - String.length(text)
    ["│ ", text, String.duplicate(" ", pad - 1), "│", @esc, "[K\r\n"]
  end

  # Read one keypress; decode common escape sequences.
  defp read_key do
    case IO.getn(:stdio, "", 1) do
      @esc -> read_escape()
      :eof -> "q"
      {:error, _} -> "q"
      ch -> printable(ch)
    end
  end

  defp read_escape do
    case IO.getn(:stdio, "", 2) do
      "[A" -> "Up"
      "[B" -> "Down"
      "[C" -> "Right"
      "[D" -> "Left"
      "[H" -> "Home"
      "[F" -> "End"
      "[" <> rest -> "ESC-seq [#{inspect(rest)}"
      other -> "ESC + #{inspect(other)}"
    end
  end

  defp printable("\r"), do: "Enter"
  defp printable("\t"), do: "Tab"
  defp printable("\d"), do: "Backspace"
  defp printable(<<c>>) when c < 32, do: "Ctrl-#{<<c + 64>>}"
  defp printable(ch), do: ch
end

TuiSpike.run()
