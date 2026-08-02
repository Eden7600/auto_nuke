defmodule AutoNuke.Tui.IOCaptureTest do
  use ExUnit.Case, async: true

  alias AutoNuke.Tui.{IOCapture, Runner}

  defp run_captured(fun) do
    {:ok, capture} = IOCapture.start(self())

    spawn(fn ->
      Process.group_leader(self(), capture)
      fun.()
    end)

    capture
  end

  defp last_output do
    assert_receive {:task_output, lines}, 500
    # Later pushes may supersede; drain to the freshest.
    drain(lines)
  end

  # Notifications are rate-limited with a 100ms trailing flush; wait past it.
  defp drain(lines) do
    receive do
      {:task_output, newer} -> drain(newer)
    after
      150 -> lines
    end
  end

  test "captures IO.puts lines in order" do
    run_captured(fn ->
      IO.puts("first")
      IO.puts("second")
    end)

    assert last_output() == ["first", "second"]
  end

  test "carriage return rewrites the current line (TaskUI wait loops)" do
    run_captured(fn ->
      IO.write("Valve ⸱⸱⸱ WAITING")
      IO.write("\rValve ⸱⸱⸱ DONE")
      IO.puts("")
    end)

    assert last_output() == ["Valve ⸱⸱⸱ DONE"]
  end

  test "ANSI escapes are stripped" do
    run_captured(fn ->
      IO.puts([IO.ANSI.yellow(), "warning!", IO.ANSI.reset()])
    end)

    assert last_output() == ["warning!"]
  end

  test "multi-line chunks split correctly" do
    run_captured(fn -> IO.write("a\nb\nc") end)

    assert last_output() == ["a", "b", "c"]
  end

  test "input requests are refused, not hung" do
    run_captured(fn ->
      result = IO.gets("? ")
      IO.puts("got: #{inspect(result)}")
    end)

    assert ["got: {:error, :enotsup}"] = last_output()
  end

  test "rapid write bursts are coalesced into few notifications" do
    run_captured(fn ->
      for i <- 1..50, do: IO.write("\rprogress #{i}")
    end)

    # Let the trailing flush land, then tally what actually arrived.
    Process.sleep(300)
    pushes = collect_pushes([])

    assert length(pushes) < 10, "expected coalescing, got #{length(pushes)} pushes"
    assert List.last(pushes) == ["progress 50"]
  end

  defp collect_pushes(acc) do
    receive do
      {:task_output, lines} -> collect_pushes([lines | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "Runner" do
    test "reports success" do
      runner = Runner.start("ok task", fn -> IO.puts("did the thing") end)

      assert_receive {:DOWN, _, :process, _, reason}, 500
      assert Runner.down?(runner, {:DOWN, runner.ref, :process, runner.pid, reason})
      assert Runner.result(reason) == :ok
      assert drain([]) == ["did the thing"]
    end

    test "reports Mix.raise as a clean error" do
      Runner.start("failing task", fn -> Mix.raise("Loop 2 is already active.") end)

      assert_receive {:DOWN, _, :process, _, reason}, 500
      assert Runner.result(reason) == {:error, "Loop 2 is already active."}
    end

    test "reports exceptions with their message" do
      Runner.start("crashing task", fn -> raise "boom" end)

      assert_receive {:DOWN, _, :process, _, reason}, 500
      assert Runner.result(reason) == {:error, "boom"}
    end

    test "cancel kills and classifies as cancelled" do
      runner = Runner.start("slow task", fn -> Process.sleep(:infinity) end)
      Runner.cancel(runner)

      assert_receive {:DOWN, _, :process, _, reason}, 500
      assert Runner.result(reason) == {:error, "Cancelled."}
    end
  end
end
