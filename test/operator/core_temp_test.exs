defmodule AutoNuke.Operator.CoreTempTest do
  use ExUnit.Case, async: false

  alias AutoNuke.LoopIntent
  alias AutoNuke.Operator.CoreTemp
  alias AutoNuke.Test.MockAPI

  @tick AutoNuke.Operator.assigned_tick(CoreTemp)

  setup do
    start_supervised!(PubSub)
    start_supervised!(LoopIntent)
    :ok
  end

  defp init(loops) do
    MockAPI.mock_get("CORE_TEMP", 330.0, times: :any)
    mock_pressures(loops)
    {:ok, state} = CoreTemp.init(loops)
    state
  end

  defp mock_pressures(loops) do
    for loop <- loops do
      MockAPI.mock_get("COOLANT_SEC_#{loop - 1}_PRESSURE", 60.0, times: :any)
    end
  end

  defp tick(state) do
    {:noreply, state} = CoreTemp.handle_info({:tick, @tick}, state)
    state
  end

  defp loops(state), do: state.monitored |> Enum.map(& &1.loop)

  test "drops a loop marked out of service" do
    state = init([1, 2, 3])
    assert loops(state) == [1, 2, 3]

    LoopIntent.set_stopped(3)
    state = tick(state)
    assert loops(state) == [1, 2]
  end

  test "adds a loop marked in service" do
    state = init([1])

    LoopIntent.set_active(2)
    mock_pressures([2])
    state = tick(state)
    assert loops(state) == [1, 2]
  end

  test "leaves loops with no known intent alone" do
    state = init([1, 2])
    state = tick(state)
    assert loops(state) == [1, 2]
  end

  test "add_loop and remove_loop record plant-wide intent" do
    state = init([1, 2])

    {:reply, :ok, state} = CoreTemp.handle_call({:remove_loop, 2}, nil, state)
    assert LoopIntent.intents() == %{2 => :stopped}

    mock_pressures([2])
    {:reply, :ok, _state} = CoreTemp.handle_call({:add_loop, 2}, nil, state)
    assert LoopIntent.intents() == %{2 => :active}
  end
end
