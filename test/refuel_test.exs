defmodule Mix.Tasks.AutoNuke.RefuelTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Test.MockAPI
  import ExUnit.CaptureIO
  alias Mix.Tasks.AutoNuke.Refuel

  defp mock_safe_reactor do
    MockAPI.mock_get("CORE_CRITICAL_MASS_REACHED", "False", times: :any)
    MockAPI.mock_get("RODS_POS_ACTUAL", 100.0, times: :any)
    MockAPI.mock_get("CORE_TEMP", 45.0, times: :any)
  end

  defp mock_bays(bays) do
    for bay <- 1..9 do
      case Map.get(bays, bay) do
        nil ->
          MockAPI.mock_get("CORE_BAY_#{bay}_STATE", "UNKNOWN", times: :any)

        {state, fissionable} ->
          MockAPI.mock_get("CORE_BAY_#{bay}_STATE", state, times: :any)
          MockAPI.mock_get("CORE_FUEL_#{bay}_FISSIONABLE", fissionable, times: :any)
      end
    end
  end

  test "refuses while the reactor is critical" do
    MockAPI.mock_get("CORE_CRITICAL_MASS_REACHED", "True", times: :any)

    assert_raise Mix.Error, ~r/critical mass/, fn ->
      capture_io(fn -> Refuel.run([]) end)
    end
  end

  test "refuses with rods out" do
    MockAPI.mock_get("CORE_CRITICAL_MASS_REACHED", "False", times: :any)
    MockAPI.mock_get("RODS_POS_ACTUAL", 40.8, times: :any)

    assert_raise Mix.Error, ~r/rods/, fn ->
      capture_io(fn -> Refuel.run([]) end)
    end
  end

  test "refuses with a hot core" do
    MockAPI.mock_get("CORE_CRITICAL_MASS_REACHED", "False", times: :any)
    MockAPI.mock_get("RODS_POS_ACTUAL", 100.0, times: :any)
    MockAPI.mock_get("CORE_TEMP", 250.0, times: :any)

    assert_raise Mix.Error, ~r/cool/, fn ->
      capture_io(fn -> Refuel.run([]) end)
    end
  end

  test "refuses when nothing is spent" do
    mock_safe_reactor()
    mock_bays(%{1 => {"INTERIOR", 99.4}, 2 => {"VACIO", 0.0}})

    assert_raise Mix.Error, ~r/No bays to refuel/, fn ->
      capture_io(fn -> Refuel.run([]) end)
    end
  end

  test "rejects uninstalled bays" do
    mock_safe_reactor()
    mock_bays(%{1 => {"INTERIOR", 99.4}})

    assert_raise Mix.Error, ~r/Unknown or uninstalled bays: 7/, fn ->
      capture_io(fn -> Refuel.run(["7"]) end)
    end
  end

  # Selection logic, short of driving the pool/piston flow: the run
  # proceeds past selection into the pool step, which reads levels we
  # leave unmocked, so the flow stops right there.
  test "spent selection picks only depleted loaded cells" do
    mock_safe_reactor()

    mock_bays(%{
      1 => {"INTERIOR", 99.4},
      2 => {"INTERIOR", 12.0},
      3 => {"VACIO", 0.0},
      4 => {"EXTERIOR", 3.5}
    })

    assert_raise RuntimeError, ~r/not mocked/, fn ->
      capture_io(fn -> Refuel.run([]) end)
    end
  end

  test "an all-empty core has nothing spent, but `all` can still fill it" do
    mock_safe_reactor()
    mock_bays(%{1 => {"VACIO", 0.0}, 2 => {"VACIO", 0.0}})

    # Empty bays are not "spent" — nothing to replace.
    assert_raise Mix.Error, ~r/No bays to refuel/, fn ->
      capture_io(fn -> Refuel.run([]) end)
    end

    # ...but `all` includes them, so the flow proceeds to the pool step.
    assert_raise RuntimeError, ~r/not mocked/, fn ->
      capture_io(fn -> Refuel.run(["all"]) end)
    end
  end
end
