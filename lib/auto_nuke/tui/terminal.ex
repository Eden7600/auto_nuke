defmodule AutoNuke.Tui.Terminal do
  @moduledoc """
  Low-level terminal control: raw mode, alternate screen, frame output.

  Requires OTP 26+ (`:shell.start_interactive/1` with the rewritten tty
  driver), which works cross-platform — including Windows Terminal.
  """

  @esc "\e"

  @doc """
  Switch the terminal into raw (key-at-a-time, no echo) mode.

  Returns `{:error, :not_a_tty}` when stdin isn't an interactive terminal,
  e.g. when output is piped.
  """
  def start_raw do
    try do
      case :shell.start_interactive({:noshell, :raw}) do
        :ok -> probe_tty()
        {:error, :already_started} -> probe_tty()
        {:error, reason} -> {:error, reason}
      end
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc "Restore line-buffered (cooked) mode."
  def stop_raw do
    :shell.start_interactive({:noshell, :cooked})
    :ok
  end

  # start_interactive can "succeed" without a usable tty; probe geometry.
  defp probe_tty do
    case size() do
      {:ok, _} -> :ok
      :error -> {:error, :not_a_tty}
    end
  end

  @doc "Current terminal size as `{:ok, {cols, rows}}`, or `:error`."
  def size do
    case {:io.columns(), :io.rows()} do
      {{:ok, cols}, {:ok, rows}} -> {:ok, {cols, rows}}
      _ -> :error
    end
  end

  @doc """
  Enter the alternate screen buffer, hide the cursor, and disable
  auto-wrap — a mis-measured wide glyph then truncates at the margin
  instead of wrapping and shifting every following line.
  """
  def enter_screen do
    IO.write([@esc, "[?1049h", @esc, "[?25l", @esc, "[?7l", @esc, "[2J"])
  end

  @doc "Restore auto-wrap and the cursor, and return to the normal screen."
  def leave_screen do
    IO.write([@esc, "[?7h", @esc, "[?25h", @esc, "[?1049l"])
  end

  @doc """
  Write one full frame (iodata) in a single write, wrapped in synchronized
  output markers so terminals that support them repaint atomically.
  """
  def put_frame(iodata) do
    IO.write([
      # Begin synchronized update, home the cursor:
      [@esc, "[?2026h", @esc, "[H"],
      iodata,
      # End synchronized update:
      [@esc, "[?2026l"]
    ])
  end
end
