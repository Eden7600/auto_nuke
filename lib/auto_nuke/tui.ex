defmodule AutoNuke.Tui do
  @moduledoc """
  The TUI run loop, in the shape of The Elm Architecture.

  An app module implements this behaviour; `run/2` owns the terminal:
  it enters raw mode + the alternate screen, starts the input pipeline,
  and loops `event → update → render` until the app returns `:stop`.

  Events delivered to `c:update/2`:

    * `{:key, key}` — see `AutoNuke.Tui.Input` for the key vocabulary
    * `{:resize, {cols, rows}}` — terminal size changed
    * `:poll` — heartbeat when no other event arrived for a while; lets
      apps do periodic work (refresh data) even with no ticks flowing
    * any other message the app's processes send to the loop
      (e.g. PubSub ticks, task-runner output)

  The terminal is always restored on the way out, crash included.
  """

  alias AutoNuke.Tui.{Canvas, Input, Terminal}

  @type state :: term()
  @type event :: term()

  @callback init(opts :: keyword()) :: state()
  @callback update(event(), state()) :: {:ok, state()} | {:stop, state()}
  @callback render(state(), {cols :: pos_integer(), rows :: pos_integer()}) :: Canvas.t()

  # Poll for terminal resize this often (ms); cheap, avoids signal handling.
  @resize_poll_ms 500

  @doc """
  Run `app` (a module implementing this behaviour) until it stops.

  Returns `:ok`, or `{:error, reason}` when the terminal can't enter
  raw mode (e.g. not run from an interactive terminal).
  """
  def run(app, opts \\ []) do
    case Terminal.start_raw() do
      :ok ->
        {:ok, input} = Input.start_link()
        Terminal.enter_screen()

        try do
          {:ok, size} = Terminal.size()
          state = app.init(opts)
          draw(app, state, size)
          loop(app, state, size)
        after
          Terminal.leave_screen()
          Terminal.stop_raw()
          Input.stop(input)
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Apply at most this many queued events before forcing a frame, so a
  # pathological message flood can't starve rendering entirely.
  @max_batch 200

  defp loop(app, state, size) do
    event =
      receive do
        {:tui_key, key} -> {:key, key}
        other -> other
      after
        @resize_poll_ms -> :resize_poll
      end

    case apply_batch(app, state, size, event, @max_batch) do
      {:stop, _state} ->
        :ok

      {:ok, state, size} ->
        # One frame per batch: when events arrive faster than we can
        # render, we coalesce instead of falling ever further behind.
        draw(app, state, size)
        loop(app, state, size)
    end
  end

  defp apply_batch(app, state, size, event, budget) do
    result =
      case handle(event, state, size) do
        {:skip, size} -> {:ok, state, size}
        {event, size} -> update(app, state, size, event)
      end

    with {:ok, state, size} <- result do
      next =
        if budget > 0 do
          receive do
            {:tui_key, key} -> {:key, key}
            other -> other
          after
            0 -> :empty
          end
        else
          :empty
        end

      case next do
        :empty -> {:ok, state, size}
        event -> apply_batch(app, state, size, event, budget - 1)
      end
    end
  end

  defp update(app, state, size, event) do
    case app.update(event, state) do
      {:ok, new_state} -> {:ok, new_state, size}
      {:stop, new_state} -> {:stop, new_state}
    end
  end

  # Quiet timeouts check for resize; an unchanged size becomes a :poll
  # heartbeat so apps can refresh themselves without any ticks flowing.
  defp handle(:resize_poll, _state, size) do
    case Terminal.size() do
      {:ok, ^size} -> {:poll, size}
      {:ok, new_size} -> {{:resize, new_size}, new_size}
      :error -> {:poll, size}
    end
  end

  defp handle(event, _state, size), do: {event, size}

  defp draw(app, state, size) do
    state
    |> app.render(size)
    |> Canvas.to_iodata()
    |> Terminal.put_frame()
  end
end
