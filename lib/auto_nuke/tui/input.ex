defmodule AutoNuke.Tui.Input do
  @moduledoc """
  Keyboard input pipeline.

  Two linked processes:

    * a **byte pump** doing blocking `IO.getn/3` reads, forwarding each char
      as a message, and
    * a **decoder** turning those messages into key events, using a receive
      timeout to tell a bare `ESC` keypress apart from an escape sequence
      (terminals deliver sequences as a burst; a lone `ESC` stays lone).

  The owner process receives `{:tui_key, key}` messages, where `key` is:

    * `{:char, grapheme}` — printable character
    * `:up | :down | :left | :right | :home | :end | :pgup | :pgdn`
    * `:enter | :tab | :backtab | :backspace | :delete | :esc`
    * `{:ctrl, char}` — e.g. `{:ctrl, ?c}`
    * `{:unknown, bytes}` — undecoded escape sequence
  """

  @esc_timeout_ms 30

  @doc "Start the input pipeline; key events are sent to `owner`."
  def start_link(owner \\ self()) do
    decoder = spawn_link(fn -> decode_loop(owner) end)
    pump = spawn_link(fn -> pump_loop(decoder) end)
    {:ok, %{decoder: decoder, pump: pump}}
  end

  @doc false
  # Start only the decoder half — used by tests to inject `{:input_char, c}`
  # messages without a real terminal behind the pump.
  def start_decoder(owner) do
    spawn_link(fn -> decode_loop(owner) end)
  end

  def stop(%{decoder: decoder, pump: pump}) do
    Process.exit(pump, :kill)
    Process.exit(decoder, :kill)
    :ok
  end

  # -- Byte pump --------------------------------------------------------------

  defp pump_loop(decoder) do
    case IO.getn(:stdio, "", 1) do
      :eof ->
        send(decoder, :input_eof)

      {:error, _reason} ->
        send(decoder, :input_eof)

      char ->
        send(decoder, {:input_char, char})
        pump_loop(decoder)
    end
  end

  # -- Decoder ----------------------------------------------------------------

  defp decode_loop(owner) do
    receive do
      {:input_char, "\e"} ->
        decode_escape(owner)
        decode_loop(owner)

      {:input_char, char} ->
        send(owner, {:tui_key, plain_key(char)})
        decode_loop(owner)

      :input_eof ->
        send(owner, {:tui_key, :eof})
    end
  end

  defp decode_escape(owner) do
    receive do
      {:input_char, "["} -> decode_csi(owner, "")
      {:input_char, "O"} -> decode_ss3(owner)
      {:input_char, char} -> send(owner, {:tui_key, {:alt, char}})
    after
      @esc_timeout_ms -> send(owner, {:tui_key, :esc})
    end
  end

  # CSI sequences: ESC [ <params> <final byte in 0x40..0x7e>
  defp decode_csi(owner, acc) do
    receive do
      {:input_char, <<c>> = char} when c in 0x40..0x7E ->
        send(owner, {:tui_key, csi_key(acc, char)})

      {:input_char, char} ->
        decode_csi(owner, acc <> char)
    after
      @esc_timeout_ms -> send(owner, {:tui_key, {:unknown, "\e[" <> acc}})
    end
  end

  # SS3 sequences (ESC O P..S): F1-F4 in some terminals.
  defp decode_ss3(owner) do
    receive do
      {:input_char, char} -> send(owner, {:tui_key, ss3_key(char)})
    after
      @esc_timeout_ms -> send(owner, {:tui_key, {:unknown, "\eO"}})
    end
  end

  defp csi_key(_, "A"), do: :up
  defp csi_key(_, "B"), do: :down
  defp csi_key(_, "C"), do: :right
  defp csi_key(_, "D"), do: :left
  defp csi_key(_, "H"), do: :home
  defp csi_key(_, "F"), do: :end
  defp csi_key(_, "Z"), do: :backtab
  defp csi_key("1", "~"), do: :home
  defp csi_key("3", "~"), do: :delete
  defp csi_key("4", "~"), do: :end
  defp csi_key("5", "~"), do: :pgup
  defp csi_key("6", "~"), do: :pgdn
  defp csi_key(params, final), do: {:unknown, "\e[" <> params <> final}

  defp ss3_key("P"), do: {:fn, 1}
  defp ss3_key("Q"), do: {:fn, 2}
  defp ss3_key("R"), do: {:fn, 3}
  defp ss3_key("S"), do: {:fn, 4}
  defp ss3_key(char), do: {:unknown, "\eO" <> char}

  defp plain_key("\r"), do: :enter
  defp plain_key("\n"), do: :enter
  defp plain_key("\t"), do: :tab
  defp plain_key("\d"), do: :backspace
  defp plain_key("\b"), do: :backspace
  defp plain_key(<<c>>) when c < 32, do: {:ctrl, c + ?a - 1}
  defp plain_key(char), do: {:char, char}
end
