defmodule AutoNuke.Tui.TelemetryTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator.SteamFlow.DemandTracker
  alias AutoNuke.Test.MockAPI
  alias AutoNuke.Tui.{Canvas, Dashboard, Data, Drills, LogBuffer}

  describe "Canvas.sparkline" do
    test "scales values across the block range" do
      assert Canvas.sparkline([0, 7], 10) == "▁█"
      assert Canvas.sparkline([0, 3.5, 7], 10) == "▁▅█"
    end

    test "flat series renders mid-height" do
      assert Canvas.sparkline([5, 5, 5], 10) == "▄▄▄"
    end

    test "non-numeric entries render as gaps" do
      assert Canvas.sparkline([0, :err, 7], 10) == "▁ █"
    end

    test "keeps only the newest samples when over width" do
      assert Canvas.sparkline([9, 9, 9, 0, 7], 2) == "▁█"
    end

    test "empty is empty" do
      assert Canvas.sparkline([], 10) == ""
    end
  end

  describe "DemandTracker.status" do
    test "reports budget, progress and projection" do
      # Timestamp 90 = day 0, 01:30 -> half the hour elapsed.
      MockAPI.mock_get("TIME_STAMP", 90, times: :any)
      MockAPI.mock_get("POWER_DEMAND_MW", 100.0, times: :any)

      status =
        DemandTracker.new()
        |> DemandTracker.status()

      assert status.demand_kw == 100_000.0
      assert status.hour_elapsed == 0.5
      # new/0 assumes 100% supplied so far; no supply samples yet, so the
      # projection is just what's been supplied: 50% of the hour's budget.
      assert status.supplied_kwh == 50_000.0
      assert status.projected_ratio == 0.5
      assert status.band == {0.95, 1.10}
    end
  end

  describe "LogBuffer" do
    test "captures logger output for the TUI" do
      LogBuffer.attach()

      try do
        require Logger
        # The test env's primary logger level is :warning.
        Logger.warning("tui log buffer smoke test")
        Process.sleep(50)

        lines = LogBuffer.tail(50)
        assert Enum.any?(lines, &(&1 =~ "tui log buffer smoke test"))
        assert Enum.any?(lines, &(&1 =~ "[warning]"))
      after
        LogBuffer.detach()
      end
    end

    test "tail is empty without a table" do
      # Never attached in this path (table may exist from the other test —
      # tail must simply not crash).
      assert is_list(LogBuffer.tail(5))
    end
  end

  describe "Drills" do
    test "every drill runs against the API mock" do
      # Zero-param drills press their variable:
      jam = Enum.find(Drills.items(), &(&1.label == "Pump jam"))
      assert jam.run.([]) == :ok
      assert MockAPI.mock_put_value("FUN_PUMP_JAM") == "PRESS"

      weather = Enum.find(Drills.items(), &(&1.label == "Set weather"))
      assert weather.run.(["storm"]) == :ok
      assert MockAPI.mock_put_value("FUN_WEATHER_CONTROL") == "STORM"
    end
  end

  describe "health issues from the valve panel" do
    test "flagged devices are reported by name" do
      MockAPI.mock_get("CORE_TEMP", 20.0, times: :any)

      panel =
        Jason.encode!(%{
          "pumps" => %{
            "BC_2_NUCLEO_CARGA" => %{"State" => %{"Overload" => true, "Dry" => false}},
            "BC_0_FINE" => %{"State" => %{"Overload" => false}}
          },
          "valves" => %{
            "AGUA_Valve_01" => %{"State" => %{"Stuck" => true}}
          }
        })

      MockAPI.mock_get("VALVE_PANEL_JSON", panel, times: :any)

      issues = Data.fetch().health.issues
      assert "BC_2_NUCLEO_CARGA: Overload" in issues
      assert "AGUA_Valve_01: Stuck" in issues
      refute Enum.any?(issues, &(&1 =~ "BC_0_FINE"))
    end
  end

  describe "diagnostics parsing" do
    test "parses the AO feed into alarms, situations and attention items" do
      MockAPI.mock_get(
        "AO_AGENT_DIAGNOSTICS_JSON",
        Jason.encode!(%{
          "active_alarms" => %{"alarms" => ["HIGH CORE TEMP"]},
          "situations" => %{"situations" => [%{"name" => "Fire in turbine hall"}]},
          "maintenance_summary" => %{
            "available" => true,
            "analysis_timestamp" => "D: 0 | 11:37",
            "age_minutes" => 40,
            "element_count" => 131,
            "attention_count" => 2,
            "attention_items" => [
              %{
                "label" => "CORE (NewCore)",
                "type" => "NUCLEO",
                "integrity_percent" => 100.0,
                "wear_percent" => 0.4,
                "radiation" => 0.0,
                "requires_maintenance" => false,
                "misaligned" => false,
                "contaminated" => false,
                "summary" => "desgaste 0.4%"
              },
              %{
                "label" => "Pump 01",
                "integrity_percent" => 55.0,
                "wear_percent" => 88.0,
                "requires_maintenance" => true,
                "misaligned" => true,
                "summary" => nil
              }
            ]
          }
        }),
        times: :any
      )

      diag = Data.diagnostics()

      assert diag.alarms == ["HIGH CORE TEMP"]
      assert diag.situations == ["Fire in turbine hall"]
      assert diag.maintenance.attention_count == 2

      pump = Enum.find(diag.maintenance.items, &(&1.label == "Pump 01"))
      assert pump.integrity == 55.0
      assert "MAINTENANCE" in pump.flags
      assert "misaligned" in pump.flags
    end

    test "degrades to :err when unreadable" do
      assert Data.diagnostics() == :err
    end
  end

  describe "dashboard integration" do
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

    defp rendered(state, size \\ {110, 34}) do
      state
      |> Dashboard.render(size)
      |> Canvas.to_iodata()
      |> IO.iodata_to_binary()
    end

    test "demand panel renders telemetry when SteamFlow reports" do
      demand = %{
        demand_kw: 150_000.0,
        supplied_kwh: 60_000.0,
        hour_elapsed: 0.4,
        supply_kw: 155_000.0,
        projected_ratio: 1.02,
        band: {0.95, 1.10},
        target: 1.05,
        override?: true,
        boost?: false,
        power_levels: [28, 28, 27]
      }

      state = Dashboard.init([])
      data = %{Data.empty() | demand: demand}
      {:ok, state} = Dashboard.update({:tui_data, data}, state)

      frame = rendered(state)
      assert frame =~ "DEMAND"
      assert frame =~ "Hour 40%"
      assert frame =~ "supplied 60.00 MWh of 150.00 MWh"
      assert frame =~ "proj 102%"
      assert frame =~ "target 105%"
      assert frame =~ "MSCV 28+28+27"
      assert frame =~ "[OVERRIDE]"
    end

    test "demand panel degrades when SteamFlow is down" do
      assert rendered(Dashboard.init([])) =~ "SteamFlow operator not running"
    end

    test "health panel lists issues in red, or all-clear" do
      state = Dashboard.init([])
      healthy = %{Data.empty() | health: %{integrity: 100.0, wear: 43.2, issues: []}}
      {:ok, state} = Dashboard.update({:tui_data, healthy}, state)
      assert rendered(state) =~ "no active issues"

      sick = %{Data.empty() | health: %{integrity: 61.0, wear: 96.0, issues: ["Rods deformed"]}}
      {:ok, state} = Dashboard.update({:tui_data, sick}, state)
      frame = rendered(state)
      assert frame =~ "Integrity 61 %"
      assert frame =~ "✖ Rods deformed"
    end

    test "history accumulates for sparklines" do
      state = Dashboard.init([])

      state =
        Enum.reduce([100.0, 200.0, 300.0], state, fn temp, acc ->
          rods = Enum.map(1..9, fn b -> {b, if(b <= 3, do: temp / 10, else: nil)} end)
          data = %{Data.empty() | core: %{Data.empty().core | temp: temp, rods: rods}}
          {:ok, acc} = Dashboard.update({:tui_data, data}, acc)
          acc
        end)

      # 3 data points pushed (plus init's async fetch may add one).
      assert length(state.history.core_temp) >= 3
      assert List.last(state.history.core_temp) == 300.0
      # Rods history averages the installed banks only:
      assert List.last(state.history.rods) == 30.0
    end

    test "d opens drills; confirm flow presses the variable" do
      state = Dashboard.init([]) |> press({:char, "d"})
      assert state.view == :drills
      assert rendered(state) =~ "DRILLS"
      assert rendered(state) =~ "Pump jam"

      # Item 0 is "Enable drills"; enter asks to confirm, y fires it.
      state = press(state, :enter)
      assert state.view == :drill_confirm
      assert rendered(state) =~ "CONFIRM DRILL"

      state = press(state, {:char, "y"})
      assert state.view == :drills
      assert {:ok, _} = state.drills.flash
      assert MockAPI.mock_put_value("FUN_REQUEST_ENABLE") == "PRESS"
    end

    test "drill prompt collects a parameter" do
      msg_index = Enum.find_index(Drills.items(), &(&1.label == "Show in-game message"))

      state =
        Dashboard.init([])
        |> press([{:char, "d"} | List.duplicate(:down, msg_index)])
        |> press(:enter)

      assert state.view == :drill_prompt

      state = press(state, [{:char, "h"}, {:char, "i"}, :enter])
      assert state.view == :drills
      assert {:ok, _} = state.drills.flash
      assert MockAPI.mock_put_value("FUN_SHOW_MESSAGE") == "hi"
    end

    test "h opens the plant health view with per-element detail" do
      diag = %{
        alarms: ["HIGH CORE TEMP"],
        situations: [],
        maintenance: %{
          available: true,
          timestamp: "D: 0 | 11:37",
          age_minutes: 40,
          element_count: 131,
          attention_count: 2,
          items: [
            %{
              label: "Pump 01",
              type: "PUMP",
              integrity: 55.0,
              wear: 88.0,
              radiation: 0,
              flags: ["MAINTENANCE"],
              summary: "needs seals"
            },
            %{
              label: "CORE (NewCore)",
              type: "NUCLEO",
              integrity: 100.0,
              wear: 0.4,
              radiation: 0,
              flags: [],
              summary: "desgaste 0.4%"
            }
          ]
        }
      }

      state = Dashboard.init([]) |> press({:char, "h"})
      assert state.view == :health
      {:ok, state} = Dashboard.update({:tui_diag, diag}, state)

      frame = rendered(state)
      assert frame =~ "PLANT HEALTH"
      assert frame =~ "✖ HIGH CORE TEMP"
      assert frame =~ "131 elements, 2 need attention"
      assert frame =~ "Pump 01"
      assert frame =~ "[MAINTENANCE]"
      assert frame =~ "└ needs seals"

      # Scroll keys move and clamp.
      state = press(state, [:pgdn, :up])
      assert state.health_scroll == 9

      state = press(state, :esc)
      assert state.view == :dash
    end

    test "health view degrades when diagnostics are unreadable" do
      state = Dashboard.init([]) |> press({:char, "h"})
      assert rendered(state) =~ "Diagnostics unavailable"
    end

    test "health panel counts only serious attention items, not wear notices" do
      item = fn label, integrity, flags ->
        %{label: label, type: "X", integrity: integrity, wear: 50.0, radiation: 0, flags: flags, summary: nil}
      end

      diag = fn items ->
        %{
          alarms: [],
          situations: [],
          maintenance: %{
            available: true,
            timestamp: "x",
            age_minutes: 1,
            element_count: 131,
            attention_count: length(items),
            items: items
          }
        }
      end

      state = Dashboard.init([])

      {:ok, state} =
        Dashboard.update(
          {:tui_data, %{Data.empty() | health: %{integrity: 100.0, wear: 1.0, issues: []}}},
          state
        )

      # Wear-only attention items are not alarming:
      {:ok, state} = Dashboard.update({:tui_diag, diag.([item.("Worn pump", 100.0, [])])}, state)
      frame = rendered(state)
      refute frame =~ "need attention"
      assert frame =~ "no active issues"

      # Integrity loss and flags are:
      {:ok, state} =
        Dashboard.update(
          {:tui_diag, diag.([item.("Cracked pipe", 87.0, []), item.("Stuck valve", 100.0, ["MAINTENANCE"]), item.("Worn pump", 100.0, [])])},
          state
        )

      frame = rendered(state)
      assert frame =~ "2 need attention"
      refute frame =~ "no active issues"
    end

    test "integrity above 99 is unstyled; wear is never alarm-coloured" do
      state = Dashboard.init([])

      {:ok, state} =
        Dashboard.update(
          {:tui_data, %{Data.empty() | health: %{integrity: 99.5, wear: 97.0, issues: []}}},
          state
        )

      frame = rendered(state)
      # Integrity at 99.5 and heavy wear render without alarm colours: the
      # style run immediately preceding each label carries no red/yellow.
      for label <- ["Integrity", "Wear"] do
        [before, _] = String.split(frame, label, parts: 2)
        run_style = String.slice(before, -12, 12)
        refute run_style =~ IO.ANSI.red(), "#{label} styled red"
        refute run_style =~ IO.ANSI.yellow(), "#{label} styled yellow"
      end
    end

    test "l toggles the log overlay" do
      state = Dashboard.init([]) |> press({:char, "l"})
      assert state.view == :log
      assert rendered(state) =~ "[l/esc] close"

      state = press(state, {:char, "l"})
      assert state.view == :dash
    end
  end
end
