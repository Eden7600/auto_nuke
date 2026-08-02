defmodule AutoNuke.Tui.MenuTest do
  use ExUnit.Case, async: true

  alias AutoNuke.Tui.Menu

  test "every item's task module exists and exports run/1" do
    for item <- Menu.items() do
      assert Code.ensure_loaded?(item.task), "#{inspect(item.task)} does not exist"
      assert function_exported?(item.task, :run, 1), "#{inspect(item.task)} lacks run/1"
    end
  end

  test "every README task is reachable from the menu" do
    tasks = Menu.items() |> Enum.map(& &1.task) |> MapSet.new()

    readme_tasks = [
      Mix.Tasks.AutoNuke.Startup,
      Mix.Tasks.AutoNuke.Loop.Start,
      Mix.Tasks.AutoNuke.Loop.Stop,
      Mix.Tasks.AutoNuke.Shutdown,
      Mix.Tasks.AutoNuke.Refill.Condenser,
      Mix.Tasks.AutoNuke.Refill.CorePool,
      Mix.Tasks.AutoNuke.Refill.CorePoolStorage,
      Mix.Tasks.AutoNuke.Refill.CoreVessel,
      Mix.Tasks.AutoNuke.Refill.Internal,
      Mix.Tasks.AutoNuke.Refill.PrimaryCst,
      Mix.Tasks.AutoNuke.Refill.Reservoir,
      Mix.Tasks.AutoNuke.Refill.Secondary,
      Mix.Tasks.AutoNuke.Refill.Truck,
      Mix.Tasks.AutoNuke.Refill.FuelCells,
      Mix.Tasks.AutoNuke.Boron.Inject,
      Mix.Tasks.AutoNuke.Boron.Filter,
      Mix.Tasks.AutoNuke.Valve
    ]

    for task <- readme_tasks do
      assert task in tasks, "#{inspect(task)} is not in the TUI menu"
    end
  end

  test "build_args drops blank optional tail args" do
    item = Enum.find(Menu.items(), &(&1.id == :startup))
    assert Menu.build_args(item, ["", ""]) == []
    assert Menu.build_args(item, ["1..2", ""]) == ["1..2"]
    assert Menu.build_args(item, ["all", "1,3"]) == ["all", "1,3"]
  end

  test "build_args splits multi-valued params into separate args" do
    item = Enum.find(Menu.items(), &(&1.id == :valve))
    assert Menu.build_args(item, ["open", "A1 B2 DV01"]) == ["open", "A1", "B2", "DV01"]

    item = Enum.find(Menu.items(), &(&1.id == :refill_secondary))
    assert Menu.build_args(item, ["50", "1 3"]) == ["50", "1", "3"]
  end

  test "params with blank required answers never reach build_args blank-mid-list" do
    # A blank required arg would shift positional args; the prompt layer
    # enforces this, but document the contract here:
    item = Enum.find(Menu.items(), &(&1.id == :boron_inject))
    assert Menu.build_args(item, ["3300", ""]) == ["3300"]
  end
end
