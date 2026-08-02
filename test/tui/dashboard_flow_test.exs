defmodule AutoNuke.Tui.DashboardFlowTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Tui.{Canvas, Dashboard, Menu}

  setup do
    start_supervised!(PubSub)
    :ok
  end

  defp initial, do: Dashboard.init([])

  defp press(state, keys) do
    Enum.reduce(List.wrap(keys), state, fn key, acc ->
      {:ok, new_state} = Dashboard.update({:key, key}, acc)
      new_state
    end)
  end

  defp rendered(state, size \\ {100, 30}) do
    state
    |> Dashboard.render(size)
    |> Canvas.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "t opens the menu, esc closes it" do
    state = initial() |> press({:char, "t"})
    assert state.view == :menu
    assert rendered(state) =~ "TASKS"
    assert rendered(state) =~ "Startup — cold start the reactor"

    state = press(state, :esc)
    assert state.view == :dash
  end

  test "menu cursor stays in bounds" do
    state = initial() |> press({:char, "t"})
    state = press(state, List.duplicate(:up, 3))
    assert state.menu.cursor == 0

    count = length(Menu.items())
    state = press(state, List.duplicate(:down, count + 5))
    assert state.menu.cursor == count - 1
  end

  test "selecting a task with params opens the prompt" do
    state = initial() |> press([{:char, "t"}, :down, :enter])

    assert state.view == :prompt
    assert state.prompt.item.id == :loop_start
    assert rendered(state) =~ "RUN TASK"
    assert rendered(state) =~ "Loop"
  end

  test "typing, correction and enter collect an answer and start the task" do
    state = initial() |> press([{:char, "t"}, :down, :enter])
    state = press(state, [{:char, "9"}, :backspace, {:char, "2"}, :enter])

    # loop_start has a single param, so the task starts.
    assert state.view == :task
    assert state.task.name =~ "Loop start"

    # The task fails fast (no operators anywhere in test), reported cleanly:
    assert_receive {:DOWN, _, :process, _, reason}, 2_000
    {:ok, state} = Dashboard.update({:DOWN, state.task.runner.ref, :process, nil, reason}, state)
    assert {:error, _} = state.task.result
    assert rendered(state) =~ "FAILED"

    # Enter closes the pane.
    state = press(state, :enter)
    assert state.view == :dash
    assert state.task == nil
  end

  test "blank required input shows an error and stays" do
    state = initial() |> press([{:char, "t"}, :down, :enter, :enter])

    assert state.view == :prompt
    assert state.prompt.error == "Required."
    assert rendered(state) =~ "Required."
  end

  test "confirm-gated task without params asks before running" do
    shutdown_index = Enum.find_index(Menu.items(), &(&1.id == :shutdown))
    state = initial() |> press([{:char, "t"} | List.duplicate(:down, shutdown_index)])
    state = press(state, :enter)

    assert state.view == :prompt
    assert state.prompt.stage == :confirm
    assert rendered(state) =~ "controlled shutdown"

    # n backs out without running anything.
    state = press(state, {:char, "n"})
    assert state.view == :menu
    assert state.task == nil
  end

  test "a running task can be backgrounded and reopened" do
    state = initial()

    runner = AutoNuke.Tui.Runner.start("slow", fn -> Process.sleep(:infinity) end)

    state = %{
      state
      | view: :task,
        task: %{name: "slow", runner: runner, lines: [], result: nil, scroll: 0}
    }

    state = press(state, {:char, "b"})
    assert state.view == :dash
    assert rendered(state) =~ "task running"

    state = press(state, {:char, "t"})
    assert state.view == :task

    AutoNuke.Tui.Runner.cancel(runner)
    assert_receive {:DOWN, _, :process, _, :killed}, 500
  end

  test "task output messages update the pane" do
    state = task_state(initial(), [])

    {:ok, state} = Dashboard.update({:task_output, ["line one", "line two"]}, state)
    assert rendered(state) =~ "line one"
    assert rendered(state) =~ "line two"
  end

  test "pgup scrolls back through task output; end snaps to the tail" do
    lines = Enum.map(1..100, &"log line #{&1}")
    state = task_state(initial(), lines)

    # Tail view shows the newest line.
    assert rendered(state) =~ "log line 100"

    state = press(state, List.duplicate(:pgup, 4))
    assert state.task.scroll == 40
    frame = rendered(state)
    assert frame =~ "↓ 40 more"
    refute frame =~ "log line 100"

    # New output while scrolled doesn't yank the view back down.
    {:ok, state} = Dashboard.update({:task_output, lines ++ ["log line 101"]}, state)
    assert state.task.scroll == 40

    state = press(state, :end)
    assert state.task.scroll == 0
    assert rendered(state) =~ "log line 101"
  end

  test "scroll never goes past the ends" do
    state = task_state(initial(), ["only line"])

    state = press(state, List.duplicate(:pgup, 5))
    assert state.task.scroll == 0

    state = press(state, :pgdn)
    assert state.task.scroll == 0
  end

  test "over-wide emoji lines are clipped to the pane, not spilled" do
    wide = String.duplicate("⚠️", 60) <> "MARKER"
    state = task_state(initial(), [wide])

    frame = rendered(state)
    # The 120-column-wide emoji run fills the pane; the tail never fits.
    refute frame =~ "MARKER"
  end

  defp task_state(state, lines) do
    %{
      state
      | view: :task,
        task: %{name: "x", runner: nil_runner(), lines: lines, result: nil, scroll: 0}
    }
  end

  defp nil_runner do
    %AutoNuke.Tui.Runner{name: "x", pid: self(), ref: make_ref(), capture: self()}
  end

  test "q asks for confirmation while operators are running" do
    stub = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(stub, AutoNuke.Operator.CoreFill)

    try do
      state = initial() |> press({:char, "q"})
      assert state.view == :quit_confirm
      assert rendered(state) =~ "Quitting stops all automation"

      # n stays; y stops.
      state = press(state, {:char, "n"})
      assert state.view == :dash

      state = press(state, {:char, "q"})
      assert {:stop, _} = Dashboard.update({:key, {:char, "y"}}, state)
    after
      Process.exit(stub, :kill)
    end
  end

  test "q quits immediately when nothing is running" do
    assert {:stop, _} = Dashboard.update({:key, {:char, "q"}}, initial())
  end

  describe "SCRAM" do
    test "S asks for confirmation; esc cancels without pressing anything" do
      state = initial() |> press({:char, "S"})
      assert state.view == :scram_confirm
      assert rendered(state) =~ "EMERGENCY SCRAM"

      state = press(state, :esc)
      assert state.view == :dash
      assert_raise RuntimeError, ~r/was not received/, fn ->
        AutoNuke.Test.MockAPI.mock_put_value("CORE_SCRAM_BUTTON")
      end
    end

    test "confirming presses the button and reports" do
      state = initial() |> press([{:char, "s"}, {:char, "y"}])

      assert state.view == :dash
      assert {:ok, msg} = state.notice
      assert msg =~ "SCRAM"
      assert AutoNuke.Test.MockAPI.mock_put_value("CORE_SCRAM_BUTTON") == "PRESS"
      assert rendered(state) =~ "rods dropping"

      # The notice clears on the next keypress.
      state = press(state, :esc)
      assert state.notice == nil
    end

    test "scram disables the rod-commanding operators" do
      {:ok, agent} = Agent.start(fn -> nil end, name: AutoNuke.Operator.ControlRods)

      try do
        initial() |> press([{:char, "S"}, {:char, "y"}])
        refute Process.alive?(agent)
      after
        if Process.alive?(agent), do: Agent.stop(agent)
      end
    end
  end

  describe "offline behaviour" do
    test "init renders immediately from the empty snapshot" do
      state = initial()
      assert state.data == AutoNuke.Tui.Data.empty()
      assert rendered(state) =~ "OFFLINE"
    end

    test "init kicks off a background fetch that reports back" do
      state = initial()
      assert state.fetching_since != nil

      # In the test env the fetch preflight fails -> empty snapshot arrives.
      before = state.fetched_at
      assert_receive {:tui_data, data}, 1_000
      {:ok, state} = Dashboard.update({:tui_data, data}, state)
      assert state.fetching_since == nil
      assert state.fetched_at > before
    end

    test "poll refetches only when due" do
      state = initial()
      assert_receive {:tui_data, data}, 1_000
      {:ok, state} = Dashboard.update({:tui_data, data}, state)

      # Immediately after a fetch, poll does nothing (500ms refresh window).
      {:ok, polled} = Dashboard.update(:poll, state)
      assert polled.fetching_since == nil

      # Once stale, poll starts a new background fetch.
      stale = System.monotonic_time(:millisecond) - 10_000
      {:ok, polled} = Dashboard.update(:poll, %{state | fetched_at: stale})
      assert polled.fetching_since != nil
      assert_receive {:tui_data, _}, 1_000
    end
  end
end
