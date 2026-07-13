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
    remote_node = ping_remote()
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

    capacity = Startup.enable_resistor_bank()
    Startup.start_secondary_circulation([loop])
    Op.SecondaryFill.stop({loop, remote_node})

    Startup.start_primary_circulation([loop], nil)
    Startup.start_turbine([loop])

    # Start our own local SteamFlow:
    {:ok, _} = Op.SteamFlow.start_link(loops: [loop], override: {capacity / 3, :mw})

    Startup.connect_to_grid([loop])

    # Put our SteamFlow to sleep:
    PubSub.unsubscribe(Op.SteamFlow, :ticker)

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
  end

  defp ping_remote do
    Node.self()
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> then(fn
      ["nonode", "nohost"] ->
        Mix.raise("This task must be run via `./task.sh auto_nuke.loop.start <loop>`.")

      ["auto_nuke_loop_start_" <> _, host] ->
        remote = :"nuke@#{host}"

        case Node.ping(remote) do
          :pong -> remote
          :pang -> Mix.raise("Cannot contact #{inspect(remote)}.  Is `./start.sh` running?")
        end
    end)
  end
end
