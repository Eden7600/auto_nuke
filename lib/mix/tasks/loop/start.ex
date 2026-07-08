defmodule Mix.Tasks.AutoNuke.Loop.Start do
  @moduledoc "Start a single loop in a running reactor"
  @shortdoc "Start a loop"

  use Mix.Task
  require Logger
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator.{SteamFlow, CoreTemp}
  alias Mix.Tasks.AutoNuke.Startup

  def run([loop]) do
    loop
    |> UI.parse_loop()
    |> startup()
  end

  @loop_emoji "\u{1F501}"

  def startup(loop) do
    remote_node = ping_remote()
    steam_flow_pid = {SteamFlow, remote_node}
    core_temp_pid = {CoreTemp, remote_node}

    steam_loops = SteamFlow.get_loops(steam_flow_pid)
    temp_loops = CoreTemp.get_loops(core_temp_pid)

    if loop in steam_loops or loop in temp_loops do
      Mix.raise("Loop #{loop} is already active.")
    end

    UI.init()
    IO.puts("#{@loop_emoji} Starting loop #{loop} #{@loop_emoji}")
    UI.log_to_file("startup.log")

    capacity = Startup.enable_resistor_bank()
    Startup.start_secondary_circulation([loop])
    Startup.start_primary_circulation([loop], nil)
    Startup.start_turbine([loop])

    # Start our own local SteamFlow:
    {:ok, _} = SteamFlow.start_link(loops: [loop], override: {capacity / 3, :mw})

    Startup.connect_to_grid([loop], false)

    # Put our SteamFlow to sleep:
    PubSub.unsubscribe(SteamFlow, :ticker)

    UI.tablet("AutoNuke Remote Control")

    UI.set_wait(
      "Core Temperature Operator",
      "ADD LOOP #{loop}",
      fn -> loop in CoreTemp.get_loops(core_temp_pid) end,
      fn -> CoreTemp.add_loop(loop, core_temp_pid) end
    )

    UI.set_wait(
      "Steam Flow Operator",
      "ADD LOOP #{loop}",
      fn -> loop in SteamFlow.get_loops(steam_flow_pid) end,
      fn -> SteamFlow.add_loop(loop, steam_flow_pid) end
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
