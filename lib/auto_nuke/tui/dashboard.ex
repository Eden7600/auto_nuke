defmodule AutoNuke.Tui.Dashboard do
  @moduledoc """
  The main TUI app: a live plant dashboard plus a task launcher.

  Views:

    * `:dash` — the dashboard; `[t]` opens the task menu
    * `:menu` — pick a plant task (arrows + enter)
    * `:prompt` — collect the task's parameters, then confirm if needed
    * `:task` — watch the running task's output; `[b]` sends it to the
      background (dashboard stays live), `[x]` cancels it

  Data refreshes on `:ticker` PubSub events, at most every 500ms; reads are
  memoized per game tick, so refreshes share HTTP requests with running
  operators. Renders sensibly whether the plant is cold, running, or
  unreachable.
  """

  @behaviour AutoNuke.Tui

  alias AutoNuke.Tui.{Canvas, Data, Drills, LogBuffer, Menu, Operators, Runner}

  # Don't refetch plant data more often than this.
  @refresh_ms 500

  # -- App behaviour ----------------------------------------------------------

  # Consider a background fetch dead (and allow a new one) after this long.
  @fetch_stuck_ms 30_000

  @impl true
  def init(_opts) do
    PubSub.subscribe(self(), :ticker)

    %{
      # Filled in asynchronously — a fetch never blocks the UI, so the TUI
      # comes up (and stays responsive) with the game offline.
      # NB: monotonic time is negative; "long ago" must be relative to now.
      data: Data.empty(),
      fetched_at: now_ms() - @refresh_ms - 1,
      fetching_since: nil,
      ticked_at: now_ms(),
      view: :dash,
      menu: %{cursor: 0},
      prompt: nil,
      task: nil,
      notice: nil,
      ops: %{cursor: 0, list: [], actions: nil, action_cursor: 0, input: nil, flash: nil},
      drills: %{cursor: 0, input: nil, flash: nil},
      history: %{core_temp: [], net_mw: [], sg_pressure: []},
      diag: %{data: :err, fetched_at: nil, fetching_since: nil},
      health_scroll: 0
    }
    |> start_fetch()
    |> start_diag_fetch()
  end

  @impl true
  def update({:key, key}, state), do: handle_key(state.view, key, %{state | notice: nil})

  def update({:tick, _n}, state) do
    state = %{state | ticked_at: now_ms()}

    state =
      if state.view in [:ops, :ops_actions] do
        put_in(state.ops.list, Operators.list())
      else
        state
      end

    {:ok, state |> maybe_fetch() |> maybe_fetch_diag()}
  end

  def update(:poll, state), do: {:ok, state |> maybe_fetch() |> maybe_fetch_diag()}

  def update({:tui_diag, diag}, state) do
    {:ok, %{state | diag: %{data: diag, fetched_at: now_ms(), fetching_since: nil}}}
  end

  # Keep this many history samples for sparklines (one per data refresh).
  @history_len 40

  def update({:tui_data, data}, state) do
    {:ok,
     %{
       state
       | data: data,
         fetched_at: now_ms(),
         fetching_since: nil,
         history: push_history(state.history, data)
     }}
  end

  def update({:task_output, lines}, %{task: %{} = task} = state) do
    {:ok, %{state | task: %{task | lines: lines}}}
  end

  def update({:DOWN, _, :process, _, reason} = down, %{task: %{} = task} = state) do
    if Runner.down?(task.runner, down) do
      {:ok, %{state | task: %{task | result: Runner.result(reason)}}}
    else
      {:ok, state}
    end
  end

  def update(_event, state), do: {:ok, state}

  defp push_history(history, data) do
    sg_avg =
      data.loops
      |> Enum.map(& &1.sg_pressure)
      |> Enum.filter(&is_number/1)
      |> case do
        [] -> :err
        ps -> Enum.sum(ps) / length(ps)
      end

    net_mw =
      case data.power.gen_kw do
        kw when is_number(kw) -> kw / 1000
        _ -> :err
      end

    %{
      core_temp: Enum.take(history.core_temp ++ [data.core.temp], -@history_len),
      net_mw: Enum.take(history.net_mw ++ [net_mw], -@history_len),
      sg_pressure: Enum.take(history.sg_pressure ++ [sg_avg], -@history_len)
    }
  end

  # -- Background data fetching -----------------------------------------------

  defp maybe_fetch(state) do
    fetching? =
      state.fetching_since != nil and now_ms() - state.fetching_since < @fetch_stuck_ms

    if not fetching? and now_ms() - state.fetched_at >= @refresh_ms do
      start_fetch(state)
    else
      state
    end
  end

  defp start_fetch(state) do
    owner = self()
    # Unlinked on purpose: a crashing or hanging fetch must not take the
    # UI with it — a stuck one is simply superseded after @fetch_stuck_ms.
    spawn(fn -> send(owner, {:tui_data, Data.fetch()}) end)
    %{state | fetching_since: now_ms()}
  end

  # The diagnostics payload is large; refresh it on a slower cadence.
  @diag_refresh_ms 5_000

  defp maybe_fetch_diag(%{diag: diag} = state) do
    fetching? =
      diag.fetching_since != nil and now_ms() - diag.fetching_since < @fetch_stuck_ms

    due? = diag.fetched_at == nil or now_ms() - diag.fetched_at >= @diag_refresh_ms

    if not fetching? and due? do
      start_diag_fetch(state)
    else
      state
    end
  end

  defp start_diag_fetch(state) do
    owner = self()
    spawn(fn -> send(owner, {:tui_diag, Data.diagnostics()}) end)
    put_in(state.diag.fetching_since, now_ms())
  end

  # -- Key handling per view --------------------------------------------------

  # Ctrl-C is the hard quit; `q` asks first when quitting stops the plant
  # automation (operators die with this VM).
  defp handle_key(_view, {:ctrl, ?c}, state), do: {:stop, state}

  defp handle_key(:dash, {:char, "q"}, state) do
    if AutoNuke.Operator.Handoff.any_running?() do
      {:ok, %{state | view: :quit_confirm}}
    else
      {:stop, state}
    end
  end

  defp handle_key(:dash, {:char, c}, state) when c in ["S", "s"],
    do: {:ok, %{state | view: :scram_confirm}}

  defp handle_key(:dash, {:char, "l"}, state), do: {:ok, %{state | view: :log}}

  defp handle_key(:dash, {:char, "h"}, state),
    do: {:ok, %{state | view: :health, health_scroll: 0}}

  defp handle_key(:health, key, state) do
    case key do
      k when k in [:esc, :enter, {:char, "h"}] ->
        {:ok, %{state | view: :dash}}

      :down ->
        {:ok, %{state | health_scroll: state.health_scroll + 1}}

      :up ->
        {:ok, %{state | health_scroll: max(state.health_scroll - 1, 0)}}

      :pgdn ->
        {:ok, %{state | health_scroll: state.health_scroll + 10}}

      :pgup ->
        {:ok, %{state | health_scroll: max(state.health_scroll - 10, 0)}}

      _ ->
        {:ok, state}
    end
  end

  defp handle_key(:log, key, state) when key in [:esc, :enter, {:char, "l"}],
    do: {:ok, %{state | view: :dash}}

  defp handle_key(:log, _key, state), do: {:ok, state}

  defp handle_key(:dash, {:char, "d"}, state),
    do: {:ok, %{state | view: :drills, drills: %{state.drills | flash: nil}}}

  defp handle_key(:drills, key, %{drills: drills} = state) do
    items = Drills.items()

    case key do
      :up ->
        {:ok, put_in(state.drills.cursor, max(drills.cursor - 1, 0))}

      :down ->
        {:ok, put_in(state.drills.cursor, min(drills.cursor + 1, length(items) - 1))}

      :enter ->
        item = Enum.at(items, drills.cursor)

        case item.params do
          [] -> {:ok, %{state | view: :drill_confirm}}
          _ -> {:ok, %{state | view: :drill_prompt, drills: %{drills | input: %{item: item, text: ""}}}}
        end

      :esc ->
        {:ok, %{state | view: :dash}}

      _ ->
        {:ok, state}
    end
  end

  defp handle_key(:drill_confirm, key, %{drills: drills} = state) do
    item = Enum.at(Drills.items(), drills.cursor)

    case key do
      {:char, c} when c in ["y", "Y"] -> {:ok, run_drill(state, item, [])}
      {:char, c} when c in ["n", "N"] -> {:ok, %{state | view: :drills}}
      :esc -> {:ok, %{state | view: :drills}}
      _ -> {:ok, state}
    end
  end

  defp handle_key(:drill_prompt, key, %{drills: %{input: input} = drills} = state) do
    case key do
      :esc ->
        {:ok, %{state | view: :drills, drills: %{drills | input: nil}}}

      :enter ->
        state = %{state | view: :drills, drills: %{drills | input: nil}}
        {:ok, run_drill(state, input.item, [input.text])}

      :backspace ->
        {:ok, put_in(state.drills.input.text, String.slice(input.text, 0..-2//1))}

      {:char, c} ->
        {:ok, put_in(state.drills.input.text, input.text <> c)}

      _ ->
        {:ok, state}
    end
  end

  defp handle_key(:scram_confirm, {:char, c}, state) when c in ["y", "Y"],
    do: {:ok, do_scram(state)}

  defp handle_key(:scram_confirm, {:char, c}, state) when c in ["n", "N"],
    do: {:ok, %{state | view: :dash}}

  defp handle_key(:scram_confirm, :esc, state), do: {:ok, %{state | view: :dash}}
  defp handle_key(:scram_confirm, _key, state), do: {:ok, state}

  defp handle_key(:quit_confirm, {:char, c}, state) when c in ["y", "Y"], do: {:stop, state}
  defp handle_key(:quit_confirm, {:char, c}, state) when c in ["n", "N"], do: {:ok, %{state | view: :dash}}
  defp handle_key(:quit_confirm, :esc, state), do: {:ok, %{state | view: :dash}}
  defp handle_key(:quit_confirm, _key, state), do: {:ok, state}

  defp handle_key(:dash, {:char, "t"}, %{task: nil} = state),
    do: {:ok, %{state | view: :menu}}

  defp handle_key(:dash, {:char, "t"}, state), do: {:ok, %{state | view: :task}}

  defp handle_key(:dash, {:char, "o"}, state) do
    {:ok, %{state | view: :ops, ops: %{state.ops | list: Operators.list(), flash: nil}}}
  end

  defp handle_key(:ops, key, %{ops: ops} = state) do
    case key do
      :up ->
        {:ok, put_in(state.ops.cursor, max(ops.cursor - 1, 0))}

      :down ->
        {:ok, put_in(state.ops.cursor, min(ops.cursor + 1, length(ops.list) - 1))}

      :enter ->
        case Enum.at(ops.list, ops.cursor) do
          nil ->
            {:ok, state}

          entry ->
            ops = %{ops | actions: {entry, Operators.actions(entry.id)}, action_cursor: 0}
            {:ok, %{state | view: :ops_actions, ops: ops}}
        end

      {:char, "s"} ->
        flash =
          try do
            AutoNuke.Operator.Handoff.adopt()
            {:ok, "Supervised operators started."}
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, inspect(reason)}
          end

        {:ok, %{state | ops: %{ops | list: Operators.list(), flash: flash}}}

      :esc ->
        {:ok, %{state | view: :dash}}

      _ ->
        {:ok, state}
    end
  end

  defp handle_key(:ops_actions, key, %{ops: %{actions: {entry, actions}} = ops} = state) do
    case key do
      :up ->
        {:ok, put_in(state.ops.action_cursor, max(ops.action_cursor - 1, 0))}

      :down ->
        {:ok, put_in(state.ops.action_cursor, min(ops.action_cursor + 1, length(actions) - 1))}

      :enter ->
        action = Enum.at(actions, ops.action_cursor)

        case action.params do
          [] -> {:ok, run_op_action(state, action, [])}
          _ -> {:ok, %{state | view: :ops_prompt, ops: %{ops | input: %{action: action, text: ""}}}}
        end

      :esc ->
        {:ok, %{state | view: :ops, ops: %{ops | actions: nil, flash: nil}}}

      _ ->
        {:ok, state}
    end
    |> then(fn {:ok, s} -> {:ok, refresh_op_actions(s, entry)} end)
  end

  defp handle_key(:ops_prompt, key, %{ops: %{input: input} = ops} = state) do
    case key do
      :esc ->
        {:ok, %{state | view: :ops_actions, ops: %{ops | input: nil}}}

      :enter ->
        state = %{state | view: :ops_actions, ops: %{ops | input: nil}}
        {:ok, run_op_action(state, input.action, [input.text])}

      :backspace ->
        {:ok, put_in(state.ops.input.text, String.slice(input.text, 0..-2//1))}

      {:char, c} ->
        {:ok, put_in(state.ops.input.text, input.text <> c)}

      _ ->
        {:ok, state}
    end
  end

  defp handle_key(:menu, key, state) do
    items = Menu.items()
    cursor = state.menu.cursor

    case key do
      :up -> {:ok, put_in(state.menu.cursor, max(cursor - 1, 0))}
      :down -> {:ok, put_in(state.menu.cursor, min(cursor + 1, length(items) - 1))}
      :enter -> {:ok, select_item(state, Enum.at(items, cursor))}
      :esc -> {:ok, %{state | view: :dash}}
      {:char, "q"} -> {:stop, state}
      _ -> {:ok, state}
    end
  end

  defp handle_key(:prompt, key, %{prompt: prompt} = state) do
    case {prompt.stage, key} do
      {_, :esc} ->
        {:ok, %{state | view: :menu, prompt: nil}}

      {:confirm, {:char, c}} when c in ["y", "Y"] ->
        {:ok, start_task(state)}

      {:confirm, {:char, c}} when c in ["n", "N"] ->
        {:ok, %{state | view: :menu, prompt: nil}}

      {:confirm, _} ->
        {:ok, state}

      {:input, :enter} ->
        {:ok, accept_input(state)}

      {:input, :backspace} ->
        {:ok, update_in(state.prompt.input, &String.slice(&1, 0..-2//1))}

      {:input, {:char, c}} ->
        {:ok, update_in(state.prompt.input, &(&1 <> c))}

      _ ->
        {:ok, state}
    end
  end

  # Scroll the task pane by this many lines per page key.
  @scroll_page 10

  defp handle_key(:task, key, %{task: task} = state) do
    running? = task != nil and task.result == nil

    case key do
      {:char, "x"} when running? ->
        Runner.cancel(task.runner)
        {:ok, state}

      {:char, "b"} when running? ->
        {:ok, %{state | view: :dash}}

      :esc when running? ->
        {:ok, %{state | view: :dash}}

      :pgup ->
        max_scroll = max(length(task.lines) - 1, 0)
        {:ok, put_in(state.task.scroll, min(task.scroll + @scroll_page, max_scroll))}

      :pgdn ->
        {:ok, put_in(state.task.scroll, max(task.scroll - @scroll_page, 0))}

      :end ->
        {:ok, put_in(state.task.scroll, 0)}

      key when key in [:enter, :esc] ->
        Runner.release(task.runner)
        {:ok, %{state | view: :dash, task: nil}}

      _ ->
        {:ok, state}
    end
  end

  defp handle_key(_view, _key, state), do: {:ok, state}

  defp run_drill(state, item, answers) do
    flash =
      case item.run.(answers) do
        :ok -> {:ok, "#{item.label} ✓"}
        {:ok, game_reply} -> {:ok, game_reply}
        {:error, msg} -> {:error, msg}
      end

    %{state | view: :drills, drills: %{state.drills | flash: flash}}
  end

  # -- SCRAM ------------------------------------------------------------------

  defp do_scram(state) do
    # Stop the operators that command reactivity first, so they can't pull
    # the rods back out from under the scram. Cooling/fill operators keep
    # running — you want those during a scram.
    for id <- [AutoNuke.Operator.ControlRods, AutoNuke.Operator.CoreTemp] do
      Operators.disable(id)
    end

    notice =
      try do
        AutoNuke.API.Misc.press_scram()
        {:ok, "SCRAM — rods dropping; ControlRods & CoreTemp disabled"}
      rescue
        e -> {:error, "SCRAM press failed: #{Exception.message(e)}"}
      catch
        :exit, reason -> {:error, "SCRAM press failed: #{inspect(reason)}"}
      end

    %{state | view: :dash, notice: notice, ops: %{state.ops | list: Operators.list()}}
  end

  # -- Operator actions -------------------------------------------------------

  defp run_op_action(state, action, answers) do
    flash =
      case action.run.(answers) do
        :ok -> {:ok, "#{action.label} ✓"}
        {:error, msg} -> {:error, msg}
      end

    %{state | ops: %{state.ops | list: Operators.list(), flash: flash}}
  end

  # Re-derive the action list (Enable/Disable flips with operator status).
  defp refresh_op_actions(%{view: :ops_actions, ops: %{actions: {entry, _}}} = state, entry) do
    put_in(state.ops.actions, {entry, Operators.actions(entry.id)})
  end

  defp refresh_op_actions(state, _entry), do: state

  # -- Prompt / task flow -----------------------------------------------------

  defp select_item(state, item) do
    prompt = %{item: item, answers: [], input: "", error: nil, stage: :input}

    cond do
      item.params != [] -> %{state | view: :prompt, prompt: prompt}
      item[:confirm] -> %{state | view: :prompt, prompt: %{prompt | stage: :confirm}}
      true -> start_task(%{state | prompt: prompt})
    end
  end

  defp accept_input(%{prompt: prompt} = state) do
    param = Enum.at(prompt.item.params, length(prompt.answers))
    input = String.trim(prompt.input)

    cond do
      input == "" and not param.optional ->
        %{state | prompt: %{prompt | error: "Required."}}

      true ->
        prompt = %{prompt | answers: prompt.answers ++ [input], input: "", error: nil}

        cond do
          length(prompt.answers) < length(prompt.item.params) ->
            %{state | prompt: prompt}

          prompt.item[:confirm] ->
            %{state | prompt: %{prompt | stage: :confirm}}

          true ->
            start_task(%{state | prompt: prompt})
        end
    end
  end

  defp start_task(%{prompt: %{item: item, answers: answers}} = state) do
    runner = Runner.start(item.label, Menu.build_run(item, answers))

    %{
      state
      | view: :task,
        prompt: nil,
        task: %{name: item.label, runner: runner, lines: [], result: nil, scroll: 0}
    }
  end

  # -- Rendering --------------------------------------------------------------

  @impl true
  def render(%{data: data} = state, {cols, rows}) do
    right_w = 24
    left_w = cols - right_w
    left = 2
    right = left_w + 1

    Canvas.new(cols, rows)
    |> Canvas.box({1, 1, cols, rows}, title: "AUTONUKE", style: [:cyan])
    |> header(data, state, cols)
    |> core_panel({3, left, left_w - 2, 6}, data, state.history)
    |> loops_panel({9, left, left_w - 2, 6}, data, state.history)
    |> demand_panel({15, left, left_w - 2, 6}, data, state.history)
    |> condenser_panel({21, left, left_w - 2, 5}, data)
    |> operators_panel({3, right, right_w - 1, 15}, data)
    |> health_panel({18, right, right_w - 1, 6}, data, state.diag)
    |> tanks_panel({24, right, right_w - 1, 9}, data)
    |> log_strip({26, left, left_w - 2, rows - 26})
    |> hint_bar(state, rows)
    |> overlay(state, {cols, rows})
  end

  defp hint_bar(canvas, state, rows) do
    hints =
      case state.task do
        nil -> " [t]asks  [o]perators  [h]ealth  [d]rills  [l]og  [S]CRAM  [q]uit "
        %{result: nil} -> " [t] show task  [o]perators  [h]ealth  [l]og  [S]CRAM  [q]uit "
        %{result: _} -> " [t] task result  [o]perators  [h]ealth  [l]og  [S]CRAM  [q]uit "
      end

    canvas = Canvas.put_text(canvas, rows, 3, hints, [:cyan])

    case state.notice do
      nil -> canvas
      {:ok, msg} -> Canvas.put_text(canvas, rows, 46, Canvas.clip(" ✓ #{msg} ", 60), [:green, :bright])
      {:error, msg} -> Canvas.put_text(canvas, rows, 46, Canvas.clip(" ✖ #{msg} ", 60), [:red, :bright])
    end
  end

  defp overlay(canvas, %{view: :scram_confirm}, {cols, rows}) do
    w = 52
    h = 6
    row0 = div(rows - h, 2)
    col0 = div(cols - w, 2)

    canvas
    |> Canvas.box({row0, col0, w, h}, title: "☢ EMERGENCY SCRAM", style: [:red, :bright])
    |> Canvas.put_text(row0 + 1, col0 + 2, "Drop all control rods NOW?", [:red, :bright])
    |> Canvas.put_text(row0 + 2, col0 + 2, "ControlRods & CoreTemp operators will be")
    |> Canvas.put_text(row0 + 3, col0 + 2, "disabled so they can't fight the scram.")
    |> Canvas.put_text(row0 + h - 1, col0 + 2, " [y] SCRAM · [n/esc] cancel ", [:red])
  end

  defp overlay(canvas, %{view: :quit_confirm}, {cols, rows}) do
    w = 52
    h = 5
    row0 = div(rows - h, 2)
    col0 = div(cols - w, 2)

    canvas
    |> Canvas.box({row0, col0, w, h}, title: "QUIT", style: [:red, :bright])
    |> Canvas.put_text(row0 + 1, col0 + 2, "Operators are running this plant.", [:bright])
    |> Canvas.put_text(row0 + 2, col0 + 2, "Quitting stops all automation. Quit anyway?")
    |> Canvas.put_text(row0 + h - 1, col0 + 2, " [y] quit · [n/esc] stay ", [:red])
  end

  defp overlay(canvas, %{view: :health} = state, size), do: health_overlay(canvas, state, size)

  defp overlay(canvas, %{view: :log}, {cols, rows}) do
    w = cols - 4
    h = rows - 2
    row0 = 2
    col0 = 3

    canvas = Canvas.box(canvas, {row0, col0, w, h}, title: "LOG", style: [:cyan, :bright])

    canvas =
      LogBuffer.tail(h - 2)
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {line, i}, acc ->
        Canvas.put_text(acc, row0 + 1 + i, col0 + 2, Canvas.clip(line, w - 4))
      end)

    Canvas.put_text(canvas, row0 + h - 1, col0 + 2, " [l/esc] close ", [:cyan])
  end

  defp overlay(canvas, %{view: view} = state, size)
       when view in [:drills, :drill_confirm, :drill_prompt] do
    canvas = drills_overlay(canvas, state, size)

    case view do
      :drill_confirm -> drill_confirm_overlay(canvas, state, size)
      :drill_prompt -> drill_prompt_overlay(canvas, state, size)
      :drills -> canvas
    end
  end

  defp overlay(canvas, %{view: :ops} = state, size), do: ops_overlay(canvas, state, size)

  defp overlay(canvas, %{view: :ops_actions} = state, size) do
    canvas |> ops_overlay(state, size) |> ops_actions_overlay(state, size)
  end

  defp overlay(canvas, %{view: :ops_prompt} = state, size) do
    canvas
    |> ops_overlay(state, size)
    |> ops_actions_overlay(state, size)
    |> ops_prompt_overlay(state, size)
  end

  defp overlay(canvas, %{view: :menu} = state, size), do: menu_overlay(canvas, state, size)
  defp overlay(canvas, %{view: :prompt} = state, size), do: prompt_overlay(canvas, state, size)
  defp overlay(canvas, %{view: :task} = state, size), do: task_overlay(canvas, state, size)
  defp overlay(canvas, _state, _size), do: canvas

  # -- Header + panels --------------------------------------------------------

  defp header(canvas, data, state, cols) do
    {label, style} =
      cond do
        data.time == :err -> {"⚠ OFFLINE", [:red, :bright]}
        data.sim_speed == 0 -> {"⏸ PAUSED", [:yellow, :bright]}
        stale?(state) -> {"⚠ STALLED", [:yellow, :bright]}
        true -> {"▶ RUNNING", [:green, :bright]}
      end

    canvas
    |> Canvas.put_text(1, cols - 24, " ⏱ #{fmt(data.time)} ", [:cyan])
    |> Canvas.put_text(1, cols - 12, " #{label} ", style)
    |> Canvas.put_text(2, 3, power_line(data.power))
    |> task_chip(state, cols)
    |> override_chip(data.overrides, cols)
  end

  # Overrides mean the operators are NOT doing their normal thing — keep
  # that permanently visible while any are active.
  defp override_chip(canvas, [], _cols), do: canvas

  defp override_chip(canvas, overrides, cols) do
    count = length(overrides)
    label = if count == 1, do: "1 OVERRIDE", else: "#{count} OVERRIDES"
    Canvas.put_text(canvas, 2, cols - 18, " ⚙ #{label} ", [:yellow, :bright])
  end

  defp task_chip(canvas, %{task: nil}, _cols), do: canvas

  defp task_chip(canvas, %{task: task}, cols) do
    {text, style} =
      case task.result do
        nil -> {"⚙ task running", [:yellow]}
        :ok -> {"✔ task done", [:green]}
        {:error, _} -> {"✖ task failed", [:red]}
      end

    Canvas.put_text(canvas, 1, cols - 40, " #{text} ", style)
  end

  # No tick from the Ticker for a while → connection to the game stalled.
  defp stale?(state), do: now_ms() - state.ticked_at > 5_000

  defp power_line(p) do
    "⚡ #{fmt_mw(p.gen_kw)} gen   #{fmt(p.demand_mw, "MW", 1)} demand   #{supply(p.supply)}"
  end

  # Where the plant's own internal power comes from right now.
  defp supply(:self), do: "supply: own turbines"
  defp supply(:external), do: "supply: external grid"
  defp supply(:diesel), do: "supply: DIESEL GENS ⚠"
  defp supply(:batteries), do: "supply: BATTERIES ⚠"
  defp supply(:err), do: "supply: ──"

  defp demand_panel(canvas, {row, col, w, _h} = rect, %{demand: demand}, history) do
    canvas = Canvas.box(canvas, rect, title: "DEMAND", style: [:green])

    case demand do
      :err ->
        Canvas.put_text(canvas, row + 2, col + 2, "SteamFlow operator not running.", [:faint])

      d ->
        {band_min, band_max} = d.band

        supplied =
          "Hour #{pct(d.hour_elapsed)}   supplied #{fmt_mwh(d.supplied_kwh)}" <>
            " of #{fmt_mwh(d.demand_kw)}"

        {proj_text, proj_style} = projection(d.projected_ratio, band_min, band_max)

        flags =
          [if(d.override?, do: "OVERRIDE"), if(d.boost?, do: "BOOST")]
          |> Enum.reject(&is_nil/1)
          |> case do
            [] -> ""
            list -> "   [#{Enum.join(list, "] [")}]"
          end

        levels =
          case d.power_levels do
            [] -> "no turbines"
            levels -> "MSCV " <> Enum.map_join(levels, "+", &to_string/1)
          end

        canvas
        |> Canvas.put_text(row + 1, col + 2, supplied)
        |> Canvas.put_text(row + 2, col + 2, proj_text, proj_style)
        |> Canvas.put_text(
          row + 2,
          col + 28,
          "target #{pct(d.target)}  (band #{pct(band_min)}–#{pct(band_max)})"
        )
        |> Canvas.put_text(
          row + 3,
          col + 2,
          "net #{fmt_mw(d.supply_kw)}  " <> Canvas.sparkline(history.net_mw, w - 24)
        )
        |> Canvas.put_text(row + 4, col + 2, Canvas.clip(levels <> flags, w - 4))
    end
  end

  defp projection(nil, _min, _max), do: {"proj ──", [:faint]}

  defp projection(ratio, band_min, band_max) do
    style =
      cond do
        ratio < band_min or ratio > band_max -> [:red, :bright]
        ratio < band_min + 0.01 or ratio > band_max - 0.01 -> [:yellow, :bright]
        true -> [:green, :bright]
      end

    {"proj #{pct(ratio)}", style}
  end

  defp health_panel(canvas, {row, col, w, h} = rect, %{health: health}, diag) do
    canvas = Canvas.box(canvas, rect, title: "HEALTH  [h] details", style: [:green])

    integrity_style =
      case health.integrity do
        i when is_number(i) and i < 50 -> [:red, :bright]
        i when is_number(i) and i < 100 -> [:yellow]
        _ -> []
      end

    wear_style =
      case health.wear do
        we when is_number(we) and we > 95 -> [:red, :bright]
        we when is_number(we) and we > 80 -> [:yellow]
        _ -> []
      end

    canvas =
      canvas
      |> Canvas.put_text(row + 1, col + 2, "Integrity #{fmt(health.integrity, "%", 0)}", integrity_style)
      |> Canvas.put_text(row + 2, col + 2, "Wear #{fmt(health.wear, "%", 1)}", wear_style)

    issue_rows = h - 4

    # Fold the maintenance attention count in as an issue line, so the
    # panel can't read "all clear" while elements need attention.
    issues =
      case {health.issues, attention_count(diag)} do
        {:err, _} -> :err
        {issues, count} when is_integer(count) and count > 0 -> issues ++ ["#{count} need attention"]
        {issues, _} -> issues
      end

    case issues do
      :err ->
        Canvas.put_text(canvas, row + 3, col + 2, "── unreadable", [:faint])

      [] ->
        Canvas.put_text(canvas, row + 3, col + 2, "✓ no active issues", [:green])

      issues ->
        {shown, rest} = Enum.split(issues, issue_rows)

        canvas =
          shown
          |> Enum.with_index()
          |> Enum.reduce(canvas, fn {issue, i}, acc ->
            Canvas.put_text(acc, row + 3 + i, col + 2, Canvas.clip("✖ #{issue}", w - 4), [:red, :bright])
          end)

        case rest do
          [] -> canvas
          more -> Canvas.put_text(canvas, row + h - 1, col + w - 12, " +#{length(more)} more ", [:red])
        end
    end
  end

  defp attention_count(%{data: %{maintenance: %{attention_count: count}}}), do: count
  defp attention_count(_diag), do: nil

  defp log_strip(canvas, {_row, _col, _w, h}) when h < 3, do: canvas

  defp log_strip(canvas, {row, col, w, h}) do
    canvas = Canvas.box(canvas, {row, col, w, h}, title: "LOG  [l] full view", style: [:cyan])

    LogBuffer.tail(h - 2)
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {line, i}, acc ->
      Canvas.put_text(acc, row + 1 + i, col + 2, Canvas.clip(line, w - 4))
    end)
  end

  defp core_panel(canvas, {row, col, w, _h} = rect, %{core: core, pzr: pzr}, history) do
    target =
      case core.target do
        :err -> ""
        t -> " → #{fmt(t, "", 1)}"
      end

    rods =
      core.rods
      |> Enum.map(fn
        {_, nil} -> "──"
        {_, :err} -> "··"
        {_, pos} -> "#{round(pos)}"
      end)
      |> Enum.join(" ")

    canvas
    |> Canvas.box(rect, title: "CORE", style: [:green])
    |> Canvas.put_text(row + 1, col + 2, "Temp #{fmt(core.temp, "°C", 1)}#{target}", [:bright])
    |> Canvas.put_text(row + 2, col + 2, "Rods #{rods} %")
    |> Canvas.put_text(row + 3, col + 2, "Boron #{fmt(core.boron_ppm, "ppm", 0)}")
    |> Canvas.put_text(row + 4, col + 2, "Fill #{fmt(core.fill, "m³", 0)}")
    |> Canvas.put_text(row + 1, col + w - 24, "PZR #{fmt(pzr.temp, "°C", 0)}")
    |> Canvas.put_text(row + 2, col + w - 24, "    #{fmt(pzr.pressure, "bar", 1)}")
    |> Canvas.put_text(row + 3, col + w - 24, "    heat #{onoff(pzr.heaters)}")
    |> Canvas.put_text(row + 4, col + w - 24, Canvas.sparkline(history.core_temp, 20), [:green])
  end

  defp loops_panel(canvas, {row, col, w, _h} = rect, %{loops: loops}, history) do
    canvas = Canvas.box(canvas, rect, title: "LOOPS", style: [:green])

    head = "     SG °C    bar   steam kg/m      gen"

    canvas =
      canvas
      |> Canvas.put_text(row + 1, col + 2, head, [:cyan])
      |> Canvas.put_text(row, col + w - 22, " bar ", [:green])
      |> Canvas.put_text(row, col + w - 17, Canvas.sparkline(history.sg_pressure, 14), [:green])

    loops
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {l, i}, acc ->
      grid =
        case l.connected do
          true -> "⚡ #{fmt_mw(l.gen_kw)} #{fmt(l.gen_hz, "Hz", 1)}"
          false -> "off grid"
          :err -> "──"
        end

      line =
        " #{circled(l.loop)}  #{fmt(l.sg_temp, "", 1)}  #{fmt(l.sg_pressure, "", 1)}   " <>
          "#{fmt(l.outlet, "", 0)}          #{grid}"

      Canvas.put_text(acc, row + 2 + i, col + 2, line)
    end)
  end

  defp condenser_panel(canvas, {row, col, _w, _h} = rect, %{condenser: c}) do
    canvas
    |> Canvas.box(rect, title: "CONDENSER / VACUUM", style: [:green])
    |> Canvas.put_text(row + 1, col + 2, "Fill #{fmt(c.fill, "%", 1)}   Temp #{fmt(c.temp, "°C", 1)}")
    |> Canvas.put_text(
      row + 2,
      col + 2,
      "Vacuum #{fmt(c.vacuum, "%", 1)}   pump #{onoff(c.vac_active)}"
    )
    |> Canvas.put_text(row + 3, col + 2, "Retention tank #{fmt(c.retention, "%", 1)}")
  end

  defp operators_panel(canvas, {row, col, w, _h} = rect, %{operators: operators} = data) do
    canvas = Canvas.box(canvas, rect, title: "OPERATORS", style: [:green])

    operators
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {{name, status}, i}, acc ->
      {mark, style} =
        case status do
          true -> {"✓", [:green]}
          {:count, n} -> {"#{n}", [:green]}
          false -> {"·", [:faint]}
        end

      overridden? =
        Enum.any?(data.overrides, &String.starts_with?(&1.op, to_string(name)))

      acc
      |> Canvas.put_text(row + 1 + i, col + 2, mark, style)
      |> Canvas.put_text(row + 1 + i, col + 4, "#{name}", if(status == false, do: [:faint], else: []))
      |> then(fn c ->
        if overridden?, do: Canvas.put_text(c, row + 1 + i, col + w - 3, "⚙", [:yellow, :bright]), else: c
      end)
    end)
  end

  defp tanks_panel(canvas, {row, col, w, h} = rect, %{tanks: tanks}) do
    canvas = Canvas.box(canvas, rect, title: "TANKS %", style: [:green])

    tanks
    |> Enum.take(max(h - 2, 0))
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {{label, fill}, i}, acc ->
      acc
      |> Canvas.put_text(row + 1 + i, col + 2, label)
      |> Canvas.put_text(row + 1 + i, col + w - 7, fmt(fill, "", 1))
    end)
  end

  # -- Operators overlays -----------------------------------------------------

  defp ops_overlay(canvas, %{ops: ops, view: view, data: data}, {cols, rows}) do
    h = min(length(ops.list) + 5, rows - 2)
    w = 58
    row0 = max(div(rows - h, 2), 2)
    col0 = max(div(cols - w, 2), 2)

    canvas =
      canvas
      |> Canvas.box({row0, col0, w, h}, title: "OPERATORS", style: [:magenta, :bright])
      |> Canvas.put_text(
        row0 + h - 1,
        col0 + 2,
        " ↑↓ · enter adjust · [s] supervise all · esc ",
        [:magenta]
      )

    # Description of the operator under the cursor.
    canvas =
      case Enum.at(ops.list, ops.cursor) do
        %{desc: desc} -> Canvas.put_text(canvas, row0 + h - 3, col0 + 2, Canvas.clip(desc, w - 4), [:cyan])
        _ -> canvas
      end

    canvas =
      ops.list
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {entry, i}, acc ->
        r = row0 + 1 + i
        selected? = i == ops.cursor and view == :ops

        {mark, mark_style} =
          case entry.status do
            :supervised -> {"✓", [:green]}
            :unsupervised -> {"!", [:yellow]}
            :stopped -> {"·", [:faint]}
          end

        base = if selected?, do: [:magenta_background, :bright], else: []

        acc
        |> then(fn c ->
          if selected?, do: Canvas.fill(c, {r, col0 + 1, w - 2, 1}, " ", [:magenta_background]), else: c
        end)
        |> Canvas.put_text(r, col0 + 2, mark, mark_style ++ if(selected?, do: [:magenta_background], else: []))
        |> Canvas.put_text(r, col0 + 4, entry.label, base)
        |> Canvas.put_text(r, col0 + w - 15, status_word(entry.status), base ++ [:faint])
        |> then(fn c ->
          if override_for(data, entry.label) do
            Canvas.put_text(c, r, col0 + w - 3, "⚙", [:yellow, :bright] ++ if(selected?, do: [:magenta_background], else: []))
          else
            c
          end
        end)
      end)

    # Flash beats override detail on the shared line; both are transient.
    selected_override =
      case Enum.at(ops.list, ops.cursor) do
        %{label: label} -> override_for(data, label)
        _ -> nil
      end

    case {ops.flash, selected_override} do
      {{:ok, msg}, _} ->
        Canvas.put_text(canvas, row0 + h - 2, col0 + 2, Canvas.clip("✓ #{msg}", w - 4), [:green])

      {{:error, msg}, _} ->
        Canvas.put_text(canvas, row0 + h - 2, col0 + 2, Canvas.clip("✖ #{msg}", w - 4), [:red, :bright])

      {nil, %{desc: desc}} ->
        Canvas.put_text(canvas, row0 + h - 2, col0 + 2, Canvas.clip("⚙ active: #{desc}", w - 4), [:yellow, :bright])

      {nil, nil} ->
        canvas
    end
  end

  # SteamFlow can have both an override and a boost — show the first,
  # the ⚙ marker covers the rest.
  defp override_for(%{overrides: overrides}, label) do
    Enum.find(overrides, &(&1.op == label))
  end

  defp status_word(:supervised), do: "running"
  defp status_word(:unsupervised), do: "unsupervised"
  defp status_word(:stopped), do: "stopped"

  defp ops_actions_overlay(canvas, %{ops: %{actions: {entry, actions}} = ops, view: view}, {cols, rows}) do
    h = length(actions) + 3
    w = 40
    row0 = max(div(rows - h, 2), 2)
    col0 = max(div(cols - w, 2) + 10, 2)

    canvas =
      canvas
      |> Canvas.box({row0, col0, w, h}, title: entry.label, style: [:yellow, :bright])
      |> Canvas.put_text(row0 + h - 1, col0 + 2, " enter run · esc back ", [:yellow])

    actions
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {action, i}, acc ->
      r = row0 + 1 + i
      selected? = i == ops.action_cursor and view == :ops_actions

      if selected? do
        acc
        |> Canvas.fill({r, col0 + 1, w - 2, 1}, " ", [:yellow_background])
        |> Canvas.put_text(r, col0 + 2, "▸ #{action.label}", [:yellow_background, :black])
      else
        Canvas.put_text(acc, r, col0 + 3, action.label)
      end
    end)
  end

  defp ops_actions_overlay(canvas, _state, _size), do: canvas

  defp ops_prompt_overlay(canvas, %{ops: %{input: %{action: action, text: text}}}, {cols, rows}) do
    [param] = action.params
    w = 40
    h = 5
    row0 = max(div(rows - h, 2) + 3, 2)
    col0 = max(div(cols - w, 2) + 14, 2)

    canvas
    |> Canvas.box({row0, col0, w, h}, title: action.label, style: [:cyan, :bright])
    |> Canvas.put_text(row0 + 1, col0 + 2, Canvas.clip("#{param.label} (#{param.hint})", w - 4))
    |> Canvas.put_text(row0 + 2, col0 + 2, Canvas.clip("> #{text}█", w - 4), [:bright])
    |> Canvas.put_text(row0 + h - 1, col0 + 2, " enter apply · esc back ", [:cyan])
  end

  defp ops_prompt_overlay(canvas, _state, _size), do: canvas

  # -- Plant health overlay ---------------------------------------------------

  defp health_overlay(canvas, %{diag: diag, data: data, health_scroll: scroll}, {cols, rows}) do
    w = min(cols - 4, 90)
    h = rows - 2
    row0 = 2
    col0 = max(div(cols - w, 2), 2)

    canvas = Canvas.box(canvas, {row0, col0, w, h}, title: "PLANT HEALTH", style: [:green, :bright])

    lines = health_lines(diag.data, data, w - 4)
    visible = h - 2
    scroll = min(scroll, max(length(lines) - visible, 0))

    canvas =
      lines
      |> Enum.slice(scroll, visible)
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {{text, style}, i}, acc ->
        Canvas.put_text(acc, row0 + 1 + i, col0 + 2, Canvas.clip(text, w - 4), style)
      end)

    footer =
      case length(lines) - visible do
        rest when rest > 0 -> " ↑↓ pgup/pgdn scroll (#{scroll}/#{rest}) · esc close "
        _ -> " esc close "
      end

    Canvas.put_text(canvas, row0 + h - 1, col0 + 2, footer, [:green])
  end

  defp health_lines(:err, _data, _width) do
    [
      {"Diagnostics unavailable.", [:red, :bright]},
      {"", []},
      {"The AO diagnostics feed could not be read — game offline", [:faint]},
      {"or the endpoint failed. Retrying every few seconds.", [:faint]}
    ]
  end

  defp health_lines(diag, data, _width) do
    vitals =
      {"Core integrity #{fmt(data.health.integrity, "%", 0)} · core wear #{fmt(data.health.wear, "%", 1)}",
       [:bright]}

    [vitals, {"", []}]
    |> Kernel.++(named_list("ALARMS", diag.alarms, [:red, :bright]))
    |> Kernel.++(named_list("SITUATIONS", diag.situations, [:yellow, :bright]))
    |> Kernel.++(maintenance_lines(diag.maintenance))
  end

  defp named_list(title, entries, style) do
    case entries do
      [] -> [{"#{title}: none", [:faint]}]
      list -> [{"#{title}:", style} | Enum.map(list, &{"  ✖ #{&1}", style})]
    end
    |> Kernel.++([{"", []}])
  end

  defp maintenance_lines(nil) do
    [{"No maintenance analysis available.", [:faint]}]
  end

  defp maintenance_lines(ms) do
    header =
      {"MAINTENANCE — analysed #{ms.timestamp} (#{ms.age_minutes} min ago), " <>
         "#{ms.element_count} elements, #{ms.attention_count} need attention", [:cyan]}

    items =
      case ms.items do
        [] ->
          [{"  ✓ nothing needs attention", [:green]}]

        items ->
          items
          |> Enum.sort_by(fn item -> {item.integrity || 100.0, -(item.wear || 0.0)} end)
          |> Enum.flat_map(&item_lines/1)
      end

    [header, {"", []} | items]
  end

  defp item_lines(item) do
    style =
      cond do
        is_number(item.integrity) and item.integrity < 70 -> [:red, :bright]
        is_number(item.integrity) and item.integrity < 100 -> [:yellow]
        item.flags != [] -> [:yellow]
        true -> []
      end

    flags = if item.flags == [], do: "", else: "  [#{Enum.join(item.flags, ", ")}]"

    radiation =
      case item.radiation do
        r when is_number(r) and r > 0 -> "  ☢ #{fmt(r, "", 1)}"
        _ -> ""
      end

    main =
      {"#{String.pad_trailing(item.label, 34)} int #{String.pad_leading(fmt(item.integrity, "%", 0), 5)}" <>
         "  wear #{String.pad_leading(fmt(item.wear, "%", 1), 6)}#{radiation}#{flags}", style}

    case item.summary do
      nil -> [main]
      "" -> [main]
      summary -> [main, {"    └ #{summary}", [:faint]}]
    end
  end

  # -- Drills overlays --------------------------------------------------------

  defp drills_overlay(canvas, %{drills: drills, view: view}, {cols, rows}) do
    items = Drills.items()
    h = min(length(items) + 4, rows - 2)
    w = 46
    row0 = max(div(rows - h, 2), 2)
    col0 = max(div(cols - w, 2), 2)

    canvas =
      canvas
      |> Canvas.box({row0, col0, w, h}, title: "⚠ DRILLS", style: [:yellow, :bright])
      |> Canvas.put_text(row0 + h - 1, col0 + 2, " ↑↓ · enter trigger · esc close ", [:yellow])

    canvas =
      items
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {item, i}, acc ->
        r = row0 + 1 + i
        selected? = i == drills.cursor and view == :drills

        if selected? do
          acc
          |> Canvas.fill({r, col0 + 1, w - 2, 1}, " ", [:yellow_background])
          |> Canvas.put_text(r, col0 + 2, "▸ #{item.label}", [:yellow_background, :black])
        else
          Canvas.put_text(acc, r, col0 + 3, item.label)
        end
      end)

    case drills.flash do
      nil -> canvas
      {:ok, msg} -> Canvas.put_text(canvas, row0 + h - 2, col0 + 2, Canvas.clip("✓ #{msg}", w - 4), [:green])
      {:error, msg} -> Canvas.put_text(canvas, row0 + h - 2, col0 + 2, Canvas.clip("✖ #{msg}", w - 4), [:red, :bright])
    end
  end

  defp drill_confirm_overlay(canvas, %{drills: drills}, {cols, rows}) do
    item = Enum.at(Drills.items(), drills.cursor)
    w = 44
    h = 5
    row0 = div(rows - h, 2)
    col0 = max(div(cols - w, 2) + 8, 2)

    canvas
    |> Canvas.box({row0, col0, w, h}, title: "CONFIRM DRILL", style: [:red, :bright])
    |> Canvas.put_text(row0 + 1, col0 + 2, Canvas.clip(item.label, w - 4), [:bright])
    |> Canvas.put_text(row0 + 2, col0 + 2, "Trigger this on the live plant?")
    |> Canvas.put_text(row0 + h - 1, col0 + 2, " [y] do it · [n/esc] back ", [:red])
  end

  defp drill_prompt_overlay(canvas, %{drills: %{input: %{item: item, text: text}}}, {cols, rows}) do
    [param] = item.params
    w = 44
    h = 5
    row0 = div(rows - h, 2) + 3
    col0 = max(div(cols - w, 2) + 10, 2)

    canvas
    |> Canvas.box({row0, col0, w, h}, title: item.label, style: [:cyan, :bright])
    |> Canvas.put_text(row0 + 1, col0 + 2, Canvas.clip("#{param.label} (#{param.hint})", w - 4))
    |> Canvas.put_text(row0 + 2, col0 + 2, Canvas.clip("> #{text}█", w - 4), [:bright])
    |> Canvas.put_text(row0 + h - 1, col0 + 2, " enter run · esc back ", [:cyan])
  end

  defp drill_prompt_overlay(canvas, _state, _size), do: canvas

  # -- Menu overlay -----------------------------------------------------------

  defp menu_overlay(canvas, %{menu: %{cursor: cursor}}, {cols, rows}) do
    items = Menu.items()
    display = display_rows(items)

    h = min(length(display) + 3, rows - 2)
    w = 58
    row0 = max(div(rows - h, 2), 2)
    col0 = max(div(cols - w, 2), 2)

    canvas =
      canvas
      |> Canvas.box({row0, col0, w, h}, title: "TASKS", style: [:magenta, :bright])
      |> Canvas.put_text(row0 + h - 1, col0 + 2, " ↑↓ move · enter run · esc close ", [:magenta])

    visible = h - 3
    cursor_display = display_index(display, cursor)
    scroll = max(cursor_display - visible + 2, 0)

    display
    |> Enum.drop(scroll)
    |> Enum.take(visible)
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {entry, i}, acc ->
      r = row0 + 1 + i

      case entry do
        {:header, group} ->
          Canvas.put_text(acc, r, col0 + 2, "· #{group} ·", [:magenta])

        {:item, item, idx} ->
          if idx == cursor do
            acc
            |> Canvas.fill({r, col0 + 1, w - 2, 1}, " ", [:magenta_background])
            |> Canvas.put_text(r, col0 + 3, "▸ #{item.label}", [:magenta_background, :bright])
          else
            Canvas.put_text(acc, r, col0 + 3, "  #{item.label}")
          end
      end
    end)
  end

  # Menu items interleaved with group headers.
  defp display_rows(items) do
    items
    |> Enum.with_index()
    |> Enum.chunk_by(fn {item, _} -> item.group end)
    |> Enum.flat_map(fn [{first, _} | _] = chunk ->
      [{:header, first.group} | Enum.map(chunk, fn {item, idx} -> {:item, item, idx} end)]
    end)
  end

  defp display_index(display, cursor) do
    Enum.find_index(display, fn
      {:item, _item, ^cursor} -> true
      _ -> false
    end) || 0
  end

  # -- Prompt overlay ---------------------------------------------------------

  defp prompt_overlay(canvas, %{prompt: prompt}, {cols, rows}) do
    w = 56
    h = 8 + length(prompt.answers)
    row0 = max(div(rows - h, 2), 2)
    col0 = max(div(cols - w, 2), 2)

    canvas =
      canvas
      |> Canvas.box({row0, col0, w, h}, title: "RUN TASK", style: [:yellow, :bright])
      |> Canvas.put_text(row0 + 1, col0 + 2, prompt.item.label, [:bright])

    canvas =
      prompt.answers
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {answer, i}, acc ->
        param = Enum.at(prompt.item.params, i)
        shown = if answer == "", do: "(default)", else: answer
        Canvas.put_text(acc, row0 + 3 + i, col0 + 4, "#{param.label}: #{shown}", [:faint])
      end)

    r = row0 + 3 + length(prompt.answers)

    case prompt.stage do
      :confirm ->
        canvas
        |> Canvas.put_text(r + 1, col0 + 2, prompt.item[:confirm] || "Run this task?", [:bright])
        |> Canvas.put_text(row0 + h - 1, col0 + 2, " [y] yes · [n/esc] no ", [:yellow])

      :input ->
        param = Enum.at(prompt.item.params, length(prompt.answers))

        canvas
        |> Canvas.put_text(r, col0 + 4, "#{param.label} (#{param.hint})")
        |> Canvas.put_text(r + 1, col0 + 4, "> #{prompt.input}█", [:bright])
        |> then(fn acc ->
          case prompt.error do
            nil -> acc
            error -> Canvas.put_text(acc, r + 2, col0 + 4, error, [:red, :bright])
          end
        end)
        |> Canvas.put_text(row0 + h - 1, col0 + 2, " enter accept · esc back ", [:yellow])
    end
  end

  # -- Task pane overlay ------------------------------------------------------

  defp task_overlay(canvas, %{task: nil} = _state, _size), do: canvas

  defp task_overlay(canvas, %{task: task}, {cols, rows}) do
    w = min(cols - 6, 76)
    h = rows - 4
    row0 = 3
    col0 = div(cols - w, 2)

    {status, style} =
      case task.result do
        nil -> {" RUNNING — [x] cancel · [b/esc] background · pgup/pgdn ", [:yellow]}
        :ok -> {" DONE — [enter] close · pgup/pgdn scroll ", [:green, :bright]}
        {:error, msg} -> {" FAILED: #{msg} — [enter] close ", [:red, :bright]}
      end

    canvas =
      canvas
      |> Canvas.box({row0, col0, w, h}, title: task.name, style: [:cyan, :bright])
      |> Canvas.put_text(row0 + h - 1, col0 + 2, Canvas.clip(status, w - 4), style)

    visible = h - 2
    total = length(task.lines)
    scroll = min(task.scroll, max(total - 1, 0))
    from = max(total - visible - scroll, 0)

    canvas =
      task.lines
      |> Enum.slice(from, visible)
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {line, i}, acc ->
        Canvas.put_text(acc, row0 + 1 + i, col0 + 2, Canvas.clip(line, w - 4))
      end)

    if scroll > 0 do
      Canvas.put_text(canvas, row0 + h - 1, col0 + w - 22, " ↓ #{scroll} more · [end] ", [:cyan, :bright])
    else
      canvas
    end
  end

  # -- Formatting -------------------------------------------------------------

  defp fmt(value, unit \\ "", decimals \\ nil)
  defp fmt(:err, _unit, _decimals), do: "──"
  defp fmt(value, "", nil), do: "#{value}"
  defp fmt(value, unit, nil), do: "#{value} #{unit}"

  defp fmt(value, unit, decimals) when is_number(value) do
    number = :erlang.float_to_binary(value / 1, decimals: decimals)
    if unit == "", do: number, else: "#{number} #{unit}"
  end

  defp fmt(value, unit, _decimals), do: fmt(value, unit, nil)

  defp fmt_mw(kw) when is_number(kw), do: "#{:erlang.float_to_binary(kw / 1000, decimals: 1)} MW"
  defp fmt_mw(_), do: "──"

  defp fmt_mwh(kwh) when is_number(kwh),
    do: "#{:erlang.float_to_binary(kwh / 1000, decimals: 2)} MWh"

  defp fmt_mwh(_), do: "──"

  defp pct(ratio) when is_number(ratio), do: "#{round(ratio * 100)}%"
  defp pct(_), do: "──"

  defp onoff(true), do: "ON"
  defp onoff(false), do: "off"
  defp onoff(_), do: "──"

  defp circled(1), do: "①"
  defp circled(2), do: "②"
  defp circled(3), do: "③"

  defp now_ms, do: System.monotonic_time(:millisecond)
end
