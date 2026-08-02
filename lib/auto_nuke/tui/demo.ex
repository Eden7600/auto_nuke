defmodule AutoNuke.Tui.Demo do
  @moduledoc """
  Engine verification app: draws boxes, echoes key events, proves overlay
  compositing. Run with `mix auto_nuke.tui --demo`. Quit with `q`.
  """

  @behaviour AutoNuke.Tui

  alias AutoNuke.Tui.Canvas

  @impl true
  def init(_opts), do: %{keys: [], count: 0, overlay: false}

  @impl true
  def update({:key, {:char, "q"}}, state), do: {:stop, state}
  def update({:key, {:ctrl, ?c}}, state), do: {:stop, state}

  def update({:key, {:char, "o"}}, state), do: {:ok, %{state | overlay: not state.overlay}}

  def update({:key, key}, state) do
    {:ok, %{state | keys: Enum.take([key | state.keys], 8), count: state.count + 1}}
  end

  def update(_event, state), do: {:ok, state}

  @impl true
  def render(state, {cols, rows}) do
    canvas =
      Canvas.new(cols, rows)
      |> Canvas.box({1, 1, cols, rows}, title: "AutoNuke TUI engine demo", style: [:cyan])
      |> Canvas.put_text(3, 4, "Terminal: #{cols}x#{rows}", [:bright])
      |> Canvas.put_text(4, 4, "Keys pressed: #{state.count}")
      |> Canvas.put_text(6, 4, "Recent keys (newest first):", [:yellow])
      |> Canvas.put_text(3, cols - 24, "☢️ wide-char alignment ▶", [:green])

    state.keys
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {key, i}, acc ->
      Canvas.put_text(acc, 7 + i, 6, inspect(key))
    end)
    |> Canvas.put_text(rows - 2, 4, "[o] toggle overlay   [q] quit", [:cyan])
    |> maybe_overlay(state, {cols, rows})
  end

  defp maybe_overlay(canvas, %{overlay: false}, _size), do: canvas

  defp maybe_overlay(canvas, %{overlay: true}, {cols, rows}) do
    w = 34
    h = 5
    row = div(rows - h, 2)
    col = div(cols - w, 2)

    canvas
    |> Canvas.box({row, col, w, h}, title: "Overlay", style: [:magenta, :bright])
    |> Canvas.put_text(row + 2, col + 3, "Modals draw over the base pane.")
  end
end
