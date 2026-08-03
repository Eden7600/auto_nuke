defmodule Mix.Tasks.AutoNuke.MeltdownTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AutoNuke.Test.MockAPI
  alias Mix.Tasks.AutoNuke.Meltdown

  setup do
    start_supervised!(PubSub)
    :ok
  end

  test "refuses on a reactor that isn't critical" do
    MockAPI.mock_get("CORE_CRITICAL_MASS_REACHED", "False", times: :any)

    assert_raise Mix.Error, ~r/isn't critical/, fn ->
      capture_io(fn -> Meltdown.run([]) end)
    end
  end

  test "rejects a nonsense rate" do
    assert_raise Mix.Error, ~r/positive number/, fn ->
      capture_io(fn -> Meltdown.run(["banana"]) end)
    end
  end

  describe "plateau detection" do
    alias AutoNuke.Smoother

    defp fill(values) do
      Enum.reduce(values, Smoother.new(Meltdown.plateau_window()), &Smoother.add(&2, &1))
    end

    test "a partial window is never a plateau" do
      refute Meltdown.plateau?(fill([100.0, 100.0, 100.0]))
    end

    test "a full flat window is a plateau" do
      window = Meltdown.plateau_window()
      assert Meltdown.plateau?(fill(List.duplicate(180.0, window)))
    end

    test "output still climbing is not a plateau" do
      window = Meltdown.plateau_window()
      climbing = Enum.map(1..window, &(100.0 + &1 * 0.5))
      refute Meltdown.plateau?(fill(climbing))
    end

    test "small wobble around a level still counts as a plateau" do
      window = Meltdown.plateau_window()
      wobble = Enum.map(1..window, fn n -> 180.0 + rem(n, 3) * 0.1 end)
      assert Meltdown.plateau?(fill(wobble))
    end
  end

  describe "abort guard" do
    # The guard is the safety-critical part: if the task dies without
    # standing it down, the plant must be scrammed.
    test "scrams when the task is killed" do
      test_pid = self()

      task =
        spawn(fn ->
          MockAPI.register_alias(self(), test_pid)
          guard_pid = Meltdown.start_abort_guard()
          send(test_pid, {:guard, guard_pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:guard, guard}, 1_000
      ref = Process.monitor(guard)

      # The guard is its own process — attribute its API calls to us.
      MockAPI.register_alias(guard, self())
      # Flush the async registration before the guard can act:
      MockAPI.unused_mocks()

      Process.exit(task, :kill)

      # The guard outlives the killed task and slams things shut.
      assert_receive {:DOWN, ^ref, :process, ^guard, :normal}, 2_000
      assert MockAPI.mock_put_value("RODS_ALL_POS_ORDERED") == 100
      assert MockAPI.mock_put_value("CORE_SCRAM_BUTTON") == "PRESS"
    end

    test "does nothing when the task stands it down" do
      test_pid = self()

      task =
        spawn(fn ->
          MockAPI.register_alias(self(), test_pid)
          guard_pid = Meltdown.start_abort_guard()
          send(test_pid, {:guard, guard_pid})

          receive do
            :finish -> send(guard_pid, :stand_down)
          end
        end)

      assert_receive {:guard, guard}, 1_000
      ref = Process.monitor(guard)
      send(task, :finish)

      assert_receive {:DOWN, ^ref, :process, ^guard, :normal}, 2_000

      assert_raise RuntimeError, ~r/not received/, fn ->
        MockAPI.mock_put_value("CORE_SCRAM_BUTTON")
      end
    end

  end
end
