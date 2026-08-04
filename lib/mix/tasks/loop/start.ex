defmodule Mix.Tasks.AutoNuke.Loop.Start do
  @moduledoc "Start a single loop in a running reactor"
  @shortdoc "Start a loop"

  use Mix.Task
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator, as: Op
  alias Mix.Tasks.AutoNuke.Startup

  def run([loop]) do
    loop
    |> UI.parse_loop()
    |> startup()
  end

  @loop_emoji "\u{1F501}"

  def startup(loop) do
    remote_node = AutoNuke.PlantNode.find("auto_nuke.loop.start <loop>")
    steam_flow_pid = {Op.SteamFlow, remote_node}
    core_temp_pid = {Op.CoreTemp, remote_node}

    steam_loops = Op.SteamFlow.get_loops(steam_flow_pid)
    temp_loops = Op.CoreTemp.get_loops(core_temp_pid)

    if loop in steam_loops or loop in temp_loops do
      Mix.raise("Loop #{loop} is already active.")
    end

    UI.init()
    IO.puts("#{@loop_emoji} Starting loop #{loop} #{@loop_emoji}")
    UI.log_to_file("startup.log")

    UI.tablet("AutoNuke Remote Control")
    UI.Operators.resistor_banks_hold({Op.ResistorBanks, remote_node})

    capacity = Startup.enable_resistor_bank()
    Startup.start_secondary_circulation([loop])
    Op.SecondaryFill.stop({loop, remote_node})

    Startup.start_primary_circulation([loop], nil)
    Startup.start_turbine([loop])

    # Start our own temporary SteamFlow for just this loop. It gets a
    # distinct name because the plant's SteamFlow may live in this very VM
    # (TUI mode) rather than on a remote node.
    {:ok, temp_steam_flow} =
      Op.SteamFlow.start_link(
        loops: [loop],
        override: {capacity / 3, :mw},
        name: __MODULE__.TempSteamFlow,
        reconcile: false
      )

    Startup.connect_to_grid([loop])

    # Put our temporary SteamFlow to sleep:
    PubSub.unsubscribe(temp_steam_flow, :ticker)

    UI.tablet("AutoNuke Remote Control")

    UI.set_wait(
      "Core Temperature Operator",
      "ADD LOOP #{loop}",
      fn -> loop in Op.CoreTemp.get_loops(core_temp_pid) end,
      fn -> Op.CoreTemp.add_loop(loop, core_temp_pid) end
    )

    UI.set_wait(
      "Steam Flow Operator",
      "ADD LOOP #{loop}",
      fn -> loop in Op.SteamFlow.get_loops(steam_flow_pid) end,
      fn -> Op.SteamFlow.add_loop(loop, steam_flow_pid) end
    )

    # The plant's SteamFlow has taken over; retire the temporary one.
    # (In task.sh mode it died with the VM; in the TUI it must be stopped.)
    GenServer.stop(temp_steam_flow)

    UI.Operators.resistor_banks_release({Op.ResistorBanks, remote_node})
  end
end
