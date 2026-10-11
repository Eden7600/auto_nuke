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
    primary_pumps_pid = {Op.PrimaryPumps, remote_node}

    steam_loops = Op.SteamFlow.get_loops(steam_flow_pid)
    temp_loops = Op.CoreTemp.get_loops(core_temp_pid)

    if loop in steam_loops or loop in temp_loops do
      Mix.raise("Loop #{loop} is already active.")
    end

    UI.init()
    IO.puts("#{@loop_emoji} Starting loop #{loop} #{@loop_emoji}")
    UI.log_to_file("startup.log")

    # The ResistorBanks operator would fight the resistor bank handling below,
    # so stand it down for the duration of this task if it's running.
    resistor_banks_was_running = suspend_resistor_banks_operator(remote_node)

    capacity = Startup.enable_resistor_bank()
    Startup.start_secondary_circulation([loop])
    Op.SecondaryFill.stop({loop, remote_node})

    Startup.start_primary_circulation([loop], Startup.startup_primary_speed())
    Startup.start_turbine([loop])

    # Start our own temporary SteamFlow for just this loop. It gets a
    # distinct name because the plant's SteamFlow may live in this very VM
    # (TUI mode) rather than on a remote node.
    {:ok, temp_steam_flow} =
      Op.SteamFlow.start_link(
        loops: [loop],
        override: {capacity / 3, :mw},
        name: __MODULE__.TempSteamFlow
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
      "Primary Pumps Operator",
      "ADD LOOP #{loop}",
      fn -> loop in Op.PrimaryPumps.get_loops(primary_pumps_pid) end,
      fn -> Op.PrimaryPumps.add_loop(loop, primary_pumps_pid) end
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

    if resistor_banks_was_running, do: resume_resistor_banks_operator(remote_node)
  end

  defp suspend_resistor_banks_operator(node) do
    running? = :erpc.call(node, Process, :whereis, [Op.ResistorBanks]) |> is_pid()

    if running? do
      UI.tablet("AutoNuke Remote Control")

      UI.set_wait(
        "Resistor Banks Operator",
        "DISABLE",
        fn -> :erpc.call(node, Process, :whereis, [Op.ResistorBanks]) |> is_nil() end,
        fn -> :erpc.call(node, AutoNuke.Tui.Operators, :disable, [Op.ResistorBanks]) end
      )
    end

    running?
  end

  defp resume_resistor_banks_operator(node) do
    UI.tablet("AutoNuke Remote Control")

    UI.set_wait(
      "Resistor Banks Operator",
      "ENABLE",
      fn -> :erpc.call(node, Process, :whereis, [Op.ResistorBanks]) |> is_pid() end,
      fn -> :erpc.call(node, AutoNuke.Tui.Operators, :enable, [Op.ResistorBanks]) end
    )
  end
end
