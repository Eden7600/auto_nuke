defmodule AutoNuke.Tui.CanvasTest do
  use ExUnit.Case, async: true

  alias AutoNuke.Tui.Canvas

  defp render_plain(canvas) do
    canvas
    |> Canvas.to_iodata()
    |> IO.iodata_to_binary()
    # Rows are emitted as ESC[<row>;1H prefixes rather than newlines.
    |> String.split(~r/\e\[\d+;1H/)
    |> Enum.drop(1)
    |> Enum.map(&String.replace(&1, ~r/\e\[[0-9;]*m/, ""))
  end

  test "blank canvas renders spaces" do
    assert render_plain(Canvas.new(4, 2)) == ["    ", "    "]
  end

  test "put_text paints at 1-based row/col and clips at the edge" do
    lines =
      Canvas.new(5, 2)
      |> Canvas.put_text(1, 2, "abc")
      |> Canvas.put_text(2, 4, "xyz")
      |> render_plain()

    assert lines == [" abc ", "   xy"]
  end

  test "out-of-bounds text is dropped, not an error" do
    lines =
      Canvas.new(3, 1)
      |> Canvas.put_text(5, 1, "abc")
      |> Canvas.put_text(0, 1, "abc")
      |> render_plain()

    assert lines == ["   "]
  end

  test "box draws borders and a title" do
    lines =
      Canvas.new(10, 3)
      |> Canvas.box({1, 1, 10, 3}, title: "Hi")
      |> render_plain()

    assert lines == [
             "┌─ Hi ───┐",
             "│        │",
             "└────────┘"
           ]
  end

  test "box clears what's underneath its interior" do
    lines =
      Canvas.new(8, 3)
      |> Canvas.put_text(2, 1, "XXXXXXXX")
      |> Canvas.box({1, 2, 6, 3})
      |> render_plain()

    assert lines == [
             " ┌────┐ ",
             "X│    │X",
             " └────┘ "
           ]
  end

  test "later paints overwrite earlier ones (overlay support)" do
    lines =
      Canvas.new(5, 1)
      |> Canvas.put_text(1, 1, "aaaaa")
      |> Canvas.put_text(1, 2, "bb")
      |> render_plain()

    assert lines == ["abbaa"]
  end

  test "wide graphemes occupy two cells" do
    lines =
      Canvas.new(6, 1)
      |> Canvas.put_text(1, 1, "☢ab")
      |> render_plain()

    # If ☢ is wide on this platform it consumes two columns.
    case :prim_tty.npwcwidth(?☢) do
      2 -> assert lines == ["☢ab  "] and String.length(hd(lines)) == 5
      _ -> assert hd(lines) =~ "ab"
    end
  end

  test "each row is absolutely positioned so overflow cannot cascade" do
    frame =
      Canvas.new(4, 3)
      |> Canvas.to_iodata()
      |> IO.iodata_to_binary()

    assert frame =~ "\e[1;1H"
    assert frame =~ "\e[2;1H"
    assert frame =~ "\e[3;1H"
    refute frame =~ "\r\n"
  end

  test "emoji with variation selector count as two columns" do
    # U+26A0 is narrow by wcwidth, but ⚠️ (with U+FE0F) renders wide.
    lines =
      Canvas.new(6, 1)
      |> Canvas.put_text(1, 1, "⚠️ab")
      |> render_plain()

    assert hd(lines) =~ "⚠️ab"
    # 2 (emoji) + 2 (ab) + 2 padding cells
    assert String.length(hd(lines)) == 5
  end

  test "clip cuts by display width, not grapheme count" do
    assert Canvas.clip("abcdef", 4) == "abcd"
    assert Canvas.clip("⚠️⚠️⚠️", 4) == "⚠️⚠️"
    assert Canvas.clip("⚠️abc", 4) == "⚠️ab"
    assert Canvas.clip("ab", 10) == "ab"
  end

  test "styled runs restore reset codes" do
    frame =
      Canvas.new(4, 1)
      |> Canvas.put_text(1, 1, "ab", [:red])
      |> Canvas.put_text(1, 3, "cd")
      |> Canvas.to_iodata()
      |> IO.iodata_to_binary()

    assert frame =~ IO.ANSI.red() <> "ab"
    assert String.ends_with?(frame, IO.ANSI.reset())
  end
end
