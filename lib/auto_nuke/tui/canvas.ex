defmodule AutoNuke.Tui.Canvas do
  @moduledoc """
  A cell-grid compositor for terminal frames.

  Drawing operations paint styled graphemes onto a `{row, col}` grid
  (1-based, top-left origin); later paints overwrite earlier ones, which is
  what makes modal overlays trivial. `to_iodata/1` serialises the grid into
  a single frame for `Terminal.put_frame/1`.

  Styles are lists of `IO.ANSI` function names, e.g. `[:cyan, :bright]`.

  Wide graphemes (emoji, CJK) occupy two cells via `:prim_tty.npwcwidth/1`,
  keeping column alignment correct.
  """

  defstruct [:cols, :rows, :cells]

  alias __MODULE__

  @blank {" ", []}

  def new(cols, rows) do
    %Canvas{cols: cols, rows: rows, cells: %{}}
  end

  @doc "Paint `text` starting at `{row, col}`, clipped to the canvas."
  def put_text(%Canvas{} = canvas, row, col, text, style \\ []) do
    text
    |> to_string()
    |> String.graphemes()
    |> Enum.reduce({canvas, col}, fn grapheme, {acc, at} ->
      {put_grapheme(acc, row, at, grapheme, style), at + width_of(grapheme)}
    end)
    |> elem(0)
  end

  @doc "Fill the rect `{row, col, w, h}` with `char`."
  def fill(%Canvas{} = canvas, {row, col, w, h}, char \\ " ", style \\ []) do
    for r <- row..(row + h - 1)//1, c <- col..(col + w - 1)//1, reduce: canvas do
      acc -> put_grapheme(acc, r, c, char, style)
    end
  end

  @doc """
  Draw a box with a border on the rect `{row, col, w, h}`, clearing its
  interior. Options: `:title` (shown in the top border), `:style`.
  """
  def box(%Canvas{} = canvas, {row, col, w, h} = rect, opts \\ []) do
    style = Keyword.get(opts, :style, [])
    bottom = row + h - 1
    right = col + w - 1

    canvas
    |> fill(rect)
    |> put_text(row, col, ["┌", String.duplicate("─", w - 2), "┐"], style)
    |> put_text(bottom, col, ["└", String.duplicate("─", w - 2), "┘"], style)
    |> then(fn acc ->
      Enum.reduce((row + 1)..(bottom - 1)//1, acc, fn r, acc ->
        acc
        |> put_grapheme(r, col, "│", style)
        |> put_grapheme(r, right, "│", style)
      end)
    end)
    |> box_title(row, col, w, opts[:title], style)
  end

  defp box_title(canvas, _row, _col, _w, nil, _style), do: canvas

  defp box_title(canvas, row, col, w, title, style) do
    label = " #{title} "
    put_text(canvas, row, col + 2, String.slice(label, 0, max(w - 4, 0)), style)
  end

  @doc """
  Serialise the canvas into one frame of iodata.

  Every row starts with an absolute cursor move — a glyph the terminal
  draws wider than we measured can then only smear its own row, never
  shift the rows below it.
  """
  def to_iodata(%Canvas{cols: cols, rows: rows, cells: cells}) do
    1..rows
    |> Enum.map(fn row ->
      1..cols
      |> Enum.map(&Map.get(cells, {row, &1}, @blank))
      |> Enum.reject(&(&1 == :continuation))
      |> Enum.chunk_by(fn {_g, style} -> style end)
      |> Enum.map(fn [{_, style} | _] = run ->
        [ansi(style) | Enum.map(run, fn {g, _} -> g end)]
      end)
      |> then(&["\e[#{row};1H", &1, IO.ANSI.reset()])
    end)
  end

  @doc "Clip `text` to at most `max_width` display columns."
  def clip(text, max_width) do
    text
    |> to_string()
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, width} ->
      case width + width_of(grapheme) do
        w when w > max_width -> {:halt, {acc, width}}
        w -> {:cont, {[grapheme | acc], w}}
      end
    end)
    |> then(fn {acc, _} -> acc |> Enum.reverse() |> Enum.join() end)
  end

  @spark_blocks ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

  @doc """
  Render numeric `values` (oldest first) as a block-character sparkline of
  at most `width` cells. Non-numeric entries render as spaces; a flat
  series renders mid-height.
  """
  def sparkline(values, width) do
    values = Enum.take(values, -width)
    numbers = Enum.filter(values, &is_number/1)

    {min, max} =
      case numbers do
        [] -> {0, 1}
        _ -> Enum.min_max(numbers)
      end

    span = max - min

    Enum.map(values, fn
      value when is_number(value) and span > 0 ->
        Enum.at(@spark_blocks, round((value - min) / span * 7))

      value when is_number(value) ->
        "▄"

      _ ->
        " "
    end)
    |> Enum.join()
  end

  @doc "Display width (in terminal columns) of `text`."
  def display_width(text) do
    text
    |> to_string()
    |> String.graphemes()
    |> Enum.reduce(0, &(&2 + width_of(&1)))
  end

  @doc """
  Paint a list of `{text, style}` segments left to right from `{row, col}`,
  clipping the whole run to `max_width` display columns.
  """
  def put_segments(%Canvas{} = canvas, row, col, segments, max_width) do
    segments
    |> Enum.reduce({canvas, col, max_width}, fn {text, style}, {acc, at, budget} ->
      if budget <= 0 do
        {acc, at, 0}
      else
        clipped = clip(text, budget)
        width = display_width(clipped)
        {put_text(acc, row, at, clipped, style), at + width, budget - width}
      end
    end)
    |> elem(0)
  end

  # -- Internals --------------------------------------------------------------

  defp put_grapheme(%Canvas{cols: cols, rows: rows} = canvas, row, col, grapheme, style)
       when row in 1..rows//1 and col in 1..cols//1 do
    cells = Map.put(canvas.cells, {row, col}, {grapheme, style})

    # A double-width grapheme also claims the next cell.
    cells =
      case width_of(grapheme) do
        2 when col + 1 <= cols -> Map.put(cells, {row, col + 1}, :continuation)
        _ -> cells
      end

    %Canvas{canvas | cells: cells}
  end

  defp put_grapheme(canvas, _row, _col, _grapheme, _style), do: canvas

  defp width_of(grapheme) do
    base =
      case String.next_codepoint(grapheme) do
        {<<cp::utf8>>, _} -> max(:prim_tty.npwcwidth(cp), 1)
        _ -> 1
      end

    # Emoji-presentation selector (U+FE0F) makes terminals draw glyphs two
    # columns wide even when wcwidth calls the base codepoint narrow
    # (⚠️ ▶️ etc. — all over TaskUI output).
    if String.contains?(grapheme, <<0xFE0F::utf8>>), do: max(base, 2), else: base
  end

  defp ansi([]), do: IO.ANSI.reset()
  defp ansi(style), do: [IO.ANSI.reset() | Enum.map(style, &apply(IO.ANSI, &1, []))]
end
