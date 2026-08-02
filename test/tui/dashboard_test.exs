defmodule AutoNuke.Tui.DashboardTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Tui.{Canvas, Dashboard, Data}

  defp state(data) do
    %{
      data: data,
      fetched_at: 0,
      fetching_since: nil,
      ticked_at: 0,
      view: :dash,
      menu: %{cursor: 0},
      prompt: nil,
      task: nil,
      notice: nil,
      ops: %{cursor: 0, list: [], actions: nil, action_cursor: 0, input: nil, flash: nil},
      drills: %{cursor: 0, input: nil, flash: nil},
      history: %{core_temp: [], net_mw: [], sg_pressure: [], rods: []},
      diag: %{data: :err, fetched_at: nil, fetching_since: nil},
      health_scroll: 0
    }
  end

  # In the test env every API read raises (unmocked MockAPI) and no operator
  # processes run, so a fetch exercises exactly the offline/cold path the
  # dashboard must survive.
  test "renders an entirely offline snapshot without crashing" do
    data = Data.fetch()

    frame =
      data
      |> state()
      |> Dashboard.render({100, 30})
      |> Canvas.to_iodata()
      |> IO.iodata_to_binary()

    assert frame =~ "AUTONUKE"
    assert frame =~ "OFFLINE"
    assert frame =~ "CORE"
    assert frame =~ "LOOPS"
    assert frame =~ "OPERATORS"
    assert frame =~ "TANKS"
    # Unreadable values render as placeholders, not crashes:
    assert frame =~ "──"
  end

  test "renders small terminals without crashing" do
    state = state(Data.fetch())

    for size <- [{80, 24}, {60, 20}, {40, 10}] do
      assert %Canvas{} = Dashboard.render(state, size)
    end
  end

  test "offline beats paused in the status chip" do
    data = %{Data.fetch() | time: :err, sim_speed: 0}

    frame =
      data
      |> state()
      |> Dashboard.render({100, 30})
      |> Canvas.to_iodata()
      |> IO.iodata_to_binary()

    assert frame =~ "OFFLINE"
    refute frame =~ "PAUSED"
  end
end
