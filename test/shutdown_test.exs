defmodule Mix.Tasks.AutoNuke.ShutdownTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AutoNuke.API.SteamGen
  alias AutoNuke.Test.MockAPI
  alias Mix.Tasks.AutoNuke.Shutdown

  # Shutdown must survive operators that aren't running — the TUI starts
  # them all off, and any of them can be disabled by hand. Previously this
  # died with {:noproc, {GenServer, :call, [{SteamFlow, :nonode@nohost}...
  setup do
    start_supervised!(PubSub)
    :ok
  end

  test "reduce_throttle closes the MSCVs itself when SteamFlow is down" do
    refute is_pid(Process.whereis(AutoNuke.Operator.SteamFlow))

    mscvs = SteamGen.all() |> Enum.map(& &1.mscv)

    # Open at first (so a write is actually needed), then reading closed
    # once it has been ordered down.
    for mscv <- mscvs do
      MockAPI.mock_get(mscv.actual_key, 30.0, times: 2)
      MockAPI.mock_get(mscv.actual_key, 2.0, times: :any)
    end

    capture_io(fn -> Shutdown.reduce_throttle(node()) end)

    # Each MSCV was ordered down directly, without any SteamFlow call:
    for mscv <- mscvs do
      assert MockAPI.mock_put_value(mscv.set_key) == 2
    end
  end
end
