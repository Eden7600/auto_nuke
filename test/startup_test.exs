defmodule Mix.Tasks.AutoNuke.StartupTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Test.MockAPI
  import ExUnit.CaptureIO
  alias Mix.Tasks.AutoNuke.Startup

  # pumps: %{loop => {primary?, secondary?}}, defaults to both installed
  defp mock_installed_loops(pumps \\ %{}) do
    json =
      for loop <- 1..3, into: %{} do
        {pri, sec} = Map.get(pumps, loop, {true, true})

        {"Loop_#{loop - 1}",
         %{
           "Primary_Pump" => pri,
           "Secondary_Pump" => sec,
           "Steam_Generator" => true,
           "Turbine" => true
         }}
      end

    MockAPI.mock_get("INSTALLED_LOOPS_JSON", Jason.encode!(json), times: :any)
  end

  # values: %{"A1" => 50, ...}, defaults to fully open
  defp mock_valve_panel(values \\ %{}) do
    valves =
      for loop <- 1..3, num <- 1..6, into: %{} do
        valve = AutoNuke.API.Valves.loop_valve(loop, num)
        value = Map.get(values, valve.short_name, 100)
        {valve.valve_panel_key, %{"Value" => value, "Actuator" => "OFF"}}
      end

    MockAPI.mock_get("VALVE_PANEL_JSON", Jason.encode!(%{"valves" => valves}), times: :any)
  end

  test "passes when pumps are installed and loop valves are open" do
    mock_installed_loops()
    mock_valve_panel()

    output = capture_io(fn -> Startup.check_loop_readiness([1, 2]) end)
    assert output =~ "All loop valves are open."
  end

  test "refuses to start a loop with a missing pump" do
    mock_installed_loops(%{2 => {true, false}})

    assert_raise Mix.Error, ~r/Missing pumps/, fn ->
      capture_io(fn -> Startup.check_loop_readiness([1, 2]) end)
    end
  end

  test "ignores missing pumps on loops we aren't starting" do
    mock_installed_loops(%{3 => {false, false}})
    mock_valve_panel()

    output = capture_io(fn -> Startup.check_loop_readiness([1, 2]) end)
    assert output =~ "All loop valves are open."
  end

  test "finds closed and partially open loop valves" do
    mock_valve_panel(%{"A1" => 0, "A3" => 50, "B6" => 99})

    closed = Startup.closed_loop_valves([1, 2])
    assert closed |> Enum.map(& &1.short_name) == ["A1", "A3", "B6"]
  end

  test "does not require valve 4 or valves of other loops" do
    mock_valve_panel(%{"A4" => 0, "B4" => 0, "C1" => 0, "C5" => 0})

    assert Startup.closed_loop_valves([1, 2]) == []
  end
end
