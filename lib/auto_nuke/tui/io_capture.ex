defmodule AutoNuke.Tui.IOCapture do
  @moduledoc """
  An Erlang I/O-protocol device that captures a task's console output.

  Set as the group leader of a task process, it receives everything the
  task writes with `IO.puts`/`IO.write` — including `AutoNuke.TaskUI`'s
  `\\r`-based progress-line rewrites — and maintains the text as a list of
  lines. After every change it pushes the visible tail to its owner as
  `{:task_output, lines}`, so the TUI just stores and renders it.

  Input requests get `{:error, :enotsup}`: TUI-run tasks have no stdin.
  """

  # Keep (and push) this many lines of scrollback.
  @max_lines 200

  # Push to the owner at most this often — busy wait loops write many
  # times a second and every push costs the owner a re-render.
  @notify_interval_ms 100

  defstruct [:owner, lines: [], current: "", notified_at: 0, flush_scheduled: false]

  alias __MODULE__, as: S

  def start(owner \\ self()) do
    # Monotonic time is negative; seed "long enough ago" relative to now so
    # the first write notifies immediately.
    seed = System.monotonic_time(:millisecond) - @notify_interval_ms
    {:ok, spawn(fn -> loop(%S{owner: owner, notified_at: seed}) end)}
  end

  def stop(pid), do: Process.exit(pid, :kill)

  defp loop(%S{} = state) do
    receive do
      {:io_request, from, reply_as, request} ->
        {reply, state} = handle(request, state)
        send(from, {:io_reply, reply_as, reply})
        loop(state)

      :flush_notify ->
        loop(notify_now(%S{state | flush_scheduled: false}))

      _other ->
        loop(state)
    end
  end

  # -- I/O protocol -----------------------------------------------------------

  defp handle({:put_chars, _encoding, chars}, state) do
    {:ok, push(state, chars)}
  end

  defp handle({:put_chars, _encoding, mod, fun, args}, state) do
    {:ok, push(state, apply(mod, fun, args))}
  rescue
    _ -> {{:error, :put_chars}, state}
  end

  defp handle({:requests, requests}, state) do
    Enum.reduce(requests, {:ok, state}, fn request, {_reply, acc} ->
      handle(request, acc)
    end)
  end

  defp handle({:setopts, _opts}, state), do: {:ok, state}
  defp handle(:getopts, state), do: {[binary: true, encoding: :unicode], state}

  # TaskUI's fixed 60-column layout fits the pane; report it as the width.
  defp handle({:get_geometry, :columns}, state), do: {AutoNuke.TaskUI.width() + 4, state}
  defp handle({:get_geometry, _}, state), do: {{:error, :enotsup}, state}

  defp handle(_request, state), do: {{:error, :enotsup}, state}

  # -- Line building ----------------------------------------------------------

  defp push(%S{} = state, chars) do
    text =
      chars
      |> IO.chardata_to_string()
      |> strip_ansi()
      |> sanitize()

    state
    |> ingest(text)
    |> notify()
  end

  # Tabs and stray control characters would move the terminal cursor when
  # rendered; keep only \r and \n as structure.
  defp sanitize(text) do
    text
    |> String.replace("\t", "  ")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
  end

  # Process \n (finish line) and \r (rewrite current line from the start).
  defp ingest(state, text) do
    text
    |> String.split(~r/(\n|\r)/, include_captures: true, trim: false)
    |> Enum.reduce(state, fn
      "\n", %S{} = acc ->
        %S{acc | lines: Enum.take([acc.current | acc.lines], @max_lines), current: ""}

      "\r", %S{} = acc ->
        %S{acc | current: ""}

      chunk, %S{} = acc ->
        %S{acc | current: acc.current <> chunk}
    end)
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;?]*[a-zA-Z]/, "")

  # Rate-limited: push immediately when quiet; during bursts, coalesce and
  # schedule a trailing flush so the final state always lands.
  defp notify(%S{} = state) do
    now = System.monotonic_time(:millisecond)

    cond do
      now - state.notified_at >= @notify_interval_ms ->
        notify_now(state)

      state.flush_scheduled ->
        state

      true ->
        Process.send_after(self(), :flush_notify, @notify_interval_ms)
        %S{state | flush_scheduled: true}
    end
  end

  defp notify_now(%S{owner: owner} = state) do
    send(owner, {:task_output, visible_lines(state)})
    %S{state | notified_at: System.monotonic_time(:millisecond)}
  end

  # Newest-last list of lines, including the in-progress one.
  defp visible_lines(%S{lines: lines, current: current}) do
    case current do
      "" -> lines
      _ -> [current | lines]
    end
    |> Enum.take(@max_lines)
    |> Enum.reverse()
  end
end
