defmodule AutoNuke.Tui.OverridesTest do
  use ExUnit.Case, async: false

  alias AutoNuke.Operator, as: Op
  alias AutoNuke.Tui.{Canvas, Dashboard, Data}

  defmodule StubOp do
    use GenServer

    def start(name, replies), do: GenServer.start(__MODULE__, replies, name: name)

    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call(msg, _from, replies), do: {:reply, Map.get(replies, msg), replies}
  end

  defp with_stub(name, replies, fun) do
    {:ok, pid} = StubOp.start(name, replies)

    try do
      fun.()
    after
      GenServer.stop(pid)
    end
  end

  describe "Data.overrides" do
    test "empty when nothing is running" do
      assert Data.overrides() == []
    end

    test "collects SteamFlow ratio override and boost" do
      replies = %{get_override: {{0.8, :ratio}, :never}, get_boost_mode: 100}

      with_stub(Op.SteamFlow, replies, fn ->
        overrides = Data.overrides()

        assert %{op: "SteamFlow", desc: "→ 80% (no expiry)"} in overrides
        assert %{op: "SteamFlow", desc: "boost until 0+01:40"} in overrides
      end)
    end

    test "collects CoreTemp override with expiry" do
      with_stub(Op.CoreTemp, %{get_override: {330.0, 1234}}, fn ->
        assert [%{op: "CoreTemp", desc: "→ 330.0°C until 0+20:34"}] = Data.overrides()
      end)
    end

    test "collects direct rods mode but not the default" do
      with_stub(Op.ControlRods, %{get_mode: :direct}, fn ->
        assert [%{op: "ControlRods", desc: "direct mode"}] = Data.overrides()
      end)

      with_stub(Op.ControlRods, %{get_mode: :predictive}, fn ->
        assert Data.overrides() == []
      end)
    end

    test "collects per-loop SecondaryFill boost" do
      with_stub(Module.concat(Op.SecondaryFill, "L2"), %{get_boost_mode: :never}, fn ->
        assert [%{op: "SecondaryFill L2", desc: "boost (no expiry)"}] = Data.overrides()
      end)
    end

    test "MW override formats as MW" do
      with_stub(Op.SteamFlow, %{get_override: {{120, :mw}, :never}}, fn ->
        assert [%{op: "SteamFlow", desc: "→ 120 MW (no expiry)"}] = Data.overrides()
      end)
    end
  end

  describe "dashboard visibility" do
    setup do
      start_supervised!(PubSub)
      :ok
    end

    defp rendered(state) do
      state
      |> Dashboard.render({110, 34})
      |> Canvas.to_iodata()
      |> IO.iodata_to_binary()
    end

    defp with_overrides(state, overrides) do
      data = %{Data.empty() | overrides: overrides}
      {:ok, state} = Dashboard.update({:tui_data, data}, state)
      state
    end

    test "header chip shows the override count" do
      state = Dashboard.init([])
      refute rendered(state) =~ "OVERRIDE"

      state = with_overrides(state, [%{op: "SteamFlow", desc: "→ 80% (no expiry)"}])
      assert rendered(state) =~ "⚙ 1 OVERRIDE"

      state =
        with_overrides(state, [
          %{op: "SteamFlow", desc: "→ 80% (no expiry)"},
          %{op: "CoreTemp", desc: "→ 330.0°C (no expiry)"}
        ])

      assert rendered(state) =~ "⚙ 2 OVERRIDES"
    end

    test "operators panel marks overridden operators" do
      state =
        Dashboard.init([])
        |> with_overrides([%{op: "SecondaryFill L2", desc: "boost (no expiry)"}])

      # The aggregated SecondaryFill row carries the marker.
      assert rendered(state) =~ "⚙"
    end

    test "ops overlay shows the selected operator's override detail" do
      state =
        Dashboard.init([])
        |> with_overrides([%{op: "SteamFlow", desc: "→ 80% until 3+14:00"}])

      {:ok, state} = Dashboard.update({:key, {:char, "o"}}, state)

      # Cursor starts on SteamFlow (first entry).
      frame = rendered(state)
      assert frame =~ "⚙ active: → 80% until 3+14:00"
    end
  end
end
