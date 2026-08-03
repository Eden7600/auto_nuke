defmodule AutoNuke.OperatorTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator

  setup do
    start_supervised!(PubSub)
    :ok
  end

  describe "unsubscribe_if_running/2" do
    test "unsubscribes a running process" do
      {:ok, agent} = Agent.start(fn -> nil end, name: :test_running_operator)
      PubSub.subscribe(agent, :ticker)

      # Let the cast land.
      Process.sleep(20)
      assert agent in PubSub.subscribers(:ticker)

      Operator.unsubscribe_if_running(:test_running_operator, :ticker)
      Process.sleep(20)

      refute agent in PubSub.subscribers(:ticker)
      Agent.stop(agent)
    end

    # Handing PubSub the name of a process that doesn't exist makes it
    # unlink(nil) and crash the PubSub server, which takes the rest of
    # the tree down with it.
    test "leaves PubSub alive when the operator isn't running" do
      pubsub = Process.whereis(PubSub)

      assert Operator.unsubscribe_if_running(:no_such_operator, :ticker) == :ok
      Process.sleep(50)

      assert Process.alive?(pubsub)
      assert Process.whereis(PubSub) == pubsub
    end
  end
end
