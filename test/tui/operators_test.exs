defmodule AutoNuke.Tui.OperatorsTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Test.MockAPI
  alias AutoNuke.Tui.{Data, Dashboard, Operators}
  alias AutoNuke.Operator, as: Op

  describe "power data" do
    # Data.fetch preflights CORE_TEMP to detect an offline game.
    defp mock_online, do: MockAPI.mock_get("CORE_TEMP", 20.0, times: :any)

    test "generation sums the per-loop generator outputs" do
      mock_online()
      MockAPI.mock_get("GENERATOR_0_KW", 1500.0, times: :any)
      MockAPI.mock_get("GENERATOR_1_KW", 2500.0, times: :any)
      # Generator 2 unmocked → unreadable → skipped from the sum.

      assert Data.fetch().power.gen_kw == 4000.0
    end

    test "supply source prefers the worst-case source" do
      mock_online()
      MockAPI.mock_get("EMERGENCY_BATTERIES_POWER_OUTPUT_KW", 12.5, times: :any)
      assert Data.fetch().power.supply == :batteries
    end

    test "supply source falls through to self" do
      mock_online()
      MockAPI.mock_get("EMERGENCY_BATTERIES_POWER_OUTPUT_KW", 0.0, times: :any)
      MockAPI.mock_get("EMERGENCY_GENERATOR_POWER_OUTPUT_KW", 0.0, times: :any)
      MockAPI.mock_get("POWER_FROM_EXTERNAL_KW", 0.0, times: :any)
      assert Data.fetch().power.supply == :self
    end
  end

  describe "operator list and actions" do
    test "everything reads stopped when nothing runs" do
      for entry <- Operators.list() do
        assert entry.status == :stopped
      end
    end

    test "a registered process without the supervisor shows unsupervised" do
      {:ok, agent} = Agent.start(fn -> nil end, name: Op.CoreFill)

      try do
        entry = Operators.list() |> Enum.find(&(&1.id == Op.CoreFill))
        assert entry.status == :unsupervised
      after
        Agent.stop(agent)
      end
    end

    test "stopped operators offer Enable first; running ones Disable" do
      assert [%{label: "Enable"} | _] = Operators.actions(Op.CoreFill)

      {:ok, agent} = Agent.start(fn -> nil end, name: Op.CoreFill)

      try do
        assert [%{label: "Disable"} | _] = Operators.actions(Op.CoreFill)
      after
        Agent.stop(agent)
      end
    end

    test "enable without a supervisor explains itself" do
      assert {:error, msg} = Operators.enable(Op.CoreFill)
      assert msg =~ "Supervisor not running"
    end

    test "disable stops an unsupervised operator" do
      {:ok, agent} = Agent.start(fn -> nil end, name: Op.CoreFill)

      assert Operators.disable(Op.CoreFill) == :ok
      refute Process.alive?(agent)
    end

    test "disable on a stopped operator errors cleanly" do
      assert {:error, "Not running."} = Operators.disable(Op.CoreFill)
    end

    test "adjustments exist for the adjustable operators" do
      labels = fn id -> Operators.actions(id) |> Enum.map(& &1.label) end

      assert Enum.any?(labels.(Op.SteamFlow), &(&1 =~ "override"))
      assert Enum.any?(labels.(Op.CoreTemp), &(&1 =~ "override"))
      assert Enum.any?(labels.(Op.ControlRods), &(&1 =~ "predictive"))
      assert Enum.any?(labels.(Module.concat(Op.SecondaryFill, "L2")), &(&1 =~ "Boost"))
    end

    test "adjustments against a stopped operator report, not crash" do
      # Override expiry (:next_hour) is computed from game time client-side.
      MockAPI.mock_get("TIME_STAMP", 1000, times: :any)

      action =
        Operators.actions(Op.CoreTemp)
        |> Enum.find(&(&1.label =~ "Set temperature"))

      assert {:error, "Not running."} = action.run.(["330"])
    end

    test "non-numeric input reports, not crashes" do
      action =
        Operators.actions(Op.CoreTemp)
        |> Enum.find(&(&1.label =~ "Set temperature"))

      assert {:error, msg} = action.run.(["banana"])
      assert msg =~ "not a number"
    end
  end

  describe "suspended supervisor (TUI default)" do
    test "children: :none starts the supervisor empty" do
      start_supervised!({AutoNuke.OperatorSupervisor, children: :none})
      assert Supervisor.which_children(AutoNuke.OperatorSupervisor) == []
      # Everything is enable-able but currently stopped:
      assert Enum.all?(Operators.list(), &(&1.status == :stopped))
    end

    test "spec_for knows every operator entry, including per-loop fills" do
      for entry <- Operators.list() do
        assert %{id: id} = AutoNuke.OperatorSupervisor.spec_for(entry.id),
               "no child spec for #{inspect(entry.id)}"

        assert id == entry.id
      end
    end

    test "enable on an empty supervisor adds the child spec and attempts a start" do
      start_supervised!({AutoNuke.OperatorSupervisor, children: :none})

      # The start is attempted (spec resolved, child added); it fails only
      # because the operator's init hits the unmocked API in tests. A failed
      # start discards the spec again, so retrying goes down the same path.
      assert {:error, _reason} = Operators.enable(Op.CoreFill)
      assert {:error, _reason} = Operators.enable(Op.CoreFill)
    end
  end

  describe "descriptions" do
    test "every operator has one, sized for the overlay" do
      for entry <- Operators.list() do
        assert is_binary(entry.desc) and entry.desc != ""
        assert String.length(entry.desc) <= 54
      end
    end
  end

  describe "dashboard ops view flow" do
    setup do
      start_supervised!(PubSub)
      :ok
    end

    defp press(state, keys) do
      Enum.reduce(List.wrap(keys), state, fn key, acc ->
        {:ok, new_state} = Dashboard.update({:key, key}, acc)
        new_state
      end)
    end

    defp rendered(state) do
      state
      |> Dashboard.render({100, 32})
      |> AutoNuke.Tui.Canvas.to_iodata()
      |> IO.iodata_to_binary()
    end

    test "o opens operators; enter opens actions; esc backs out" do
      state = Dashboard.init([]) |> press({:char, "o"})
      assert state.view == :ops
      assert rendered(state) =~ "OPERATORS"
      assert rendered(state) =~ "supervise all"
      # The selected operator's description is shown:
      assert rendered(state) =~ "grid power demand"

      state_down = press(state, :down)
      assert rendered(state_down) =~ "60 bar SG pressure"

      state = press(state, :enter)
      assert state.view == :ops_actions
      assert rendered(state) =~ "Enable"

      state = press(state, [:esc, :esc])
      assert state.view == :dash
    end

    test "running an action shows a flash" do
      {:ok, agent} = Agent.start(fn -> nil end, name: Op.CoreFill)

      try do
        cursor = Enum.find_index(Operators.list(), &(&1.id == Op.CoreFill))

        state =
          Dashboard.init([])
          |> press([{:char, "o"} | List.duplicate(:down, cursor)])
          |> press([:enter, :enter])

        # Disable ran against the stub:
        refute Process.alive?(agent)
        assert {:ok, _} = state.ops.flash
        assert rendered(state) =~ "Disable ✓"
      after
        if Process.alive?(agent), do: Agent.stop(agent)
      end
    end

    test "prompted action collects input then applies" do
      MockAPI.mock_get("TIME_STAMP", 1000, times: :any)
      cursor = Enum.find_index(Operators.list(), &(&1.id == Op.CoreTemp))

      state =
        Dashboard.init([])
        |> press([{:char, "o"} | List.duplicate(:down, cursor)])
        # Enable(0) → Set override(1):
        |> press([:enter, :down, :enter])

      assert state.view == :ops_prompt
      assert rendered(state) =~ "Temperature"

      state = press(state, [{:char, "3"}, {:char, "3"}, {:char, "0"}, :enter])
      assert state.view == :ops_actions
      # CoreTemp isn't running, so the action reports that:
      assert {:error, "Not running."} = state.ops.flash
    end
  end
end
