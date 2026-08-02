defmodule AutoNuke.Tui.InputTest do
  use ExUnit.Case, async: true

  alias AutoNuke.Tui.Input

  defp decode(chars) do
    decoder = Input.start_decoder(self())
    Enum.each(chars, &send(decoder, {:input_char, &1}))
    decoder
  end

  defp assert_key(key) do
    assert_receive {:tui_key, ^key}, 200
  end

  test "printable characters" do
    decode(["a", "Z", "é"])
    assert_key({:char, "a"})
    assert_key({:char, "Z"})
    assert_key({:char, "é"})
  end

  test "control characters" do
    decode(["\r", "\t", "\d", <<3>>])
    assert_key(:enter)
    assert_key(:tab)
    assert_key(:backspace)
    assert_key({:ctrl, ?c})
  end

  test "arrow keys arrive as a CSI burst" do
    decode(["\e", "[", "A", "\e", "[", "B", "\e", "[", "C", "\e", "[", "D"])
    assert_key(:up)
    assert_key(:down)
    assert_key(:right)
    assert_key(:left)
  end

  test "multi-byte CSI sequences (page up/down, delete)" do
    decode(["\e", "[", "5", "~", "\e", "[", "6", "~", "\e", "[", "3", "~"])
    assert_key(:pgup)
    assert_key(:pgdn)
    assert_key(:delete)
  end

  test "bare ESC resolves via timeout" do
    decode(["\e"])
    assert_key(:esc)
  end

  test "ESC then a later key is not swallowed" do
    decoder = decode(["\e"])
    assert_key(:esc)

    send(decoder, {:input_char, "x"})
    assert_key({:char, "x"})
  end

  test "alt-modified key" do
    decode(["\e", "f"])
    assert_key({:alt, "f"})
  end

  test "eof is delivered" do
    decoder = Input.start_decoder(self())
    send(decoder, :input_eof)
    assert_key(:eof)
  end
end
