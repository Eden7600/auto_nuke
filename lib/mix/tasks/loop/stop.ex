defmodule Mix.Tasks.AutoNuke.Loop.Stop do
  @moduledoc "Stop a single loop in a running reactor"
  @shortdoc "Stop a loop"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.API.SteamGen
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator.SteamFlow
  alias Mix.Tasks.AutoNuke.Startup

  def run([loop]) do
    loop
    |> UI.parse_loop()
    |> stop()
  end

  @loop_emoji "\u{1F501}"

  def stop(loop) do
    remote_node = ping_remote()
    steam_flow_pid = {SteamFlow, remote_node}
    steam_gen = SteamGen.for_loop(loop)

    UI.init()
    IO.puts("#{@loop_emoji} Stopping loop #{loop} #{@loop_emoji}")
    UI.log_to_file("startup.log")

    Startup.enable_resistor_bank()

    UI.tablet("AutoNuke Remote Control")

    UI.set_wait(
      "Steam Flow Operator",
      "REMOVE LOOP #{loop}",
      fn -> loop not in SteamFlow.get_loops(steam_flow_pid) end,
      fn -> SteamFlow.remove_loop(loop, steam_flow_pid) end
    )

    UI.wait("Turbine 0#{loop} Circuit Breaker", "OPEN", fn ->
      API.get_boolean("GENERATOR_#{loop - 1}_BREAKER")
    end)

    UI.console("Generation & Distribution")

    UI.console("Generation & Distribution")
    steam_gen.bypass |> UI.Valves.set(100, wait: false)

    UI.console("Steam Generator")
    steam_gen.mscv |> UI.Valves.set(0, wait: false)

    UI.console("Coolant System")
    API.Pumps.primary(loop) |> UI.Pumps.stop()

    UI.console("Steam Generator")

    UI.set_wait(
      "Pressure Relief Vent 0#{loop}",
      "OPEN",
      fn -> SteamGen.get_vent_open?(steam_gen) end,
      fn -> SteamGen.set_vent_open(steam_gen, true) end
    )

    temp = SteamGen.get_temperature(steam_gen)

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(max(temp, 100), 50, "°C", 1),
      label: "Temperature",
      current_fn: fn -> SteamGen.get_temperature(steam_gen) end,
      done_fn: &(&1 <= 50)
    )

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(70, 1, " bar", 1),
      label: "Pressure",
      current_fn: fn -> SteamGen.get_pressure(steam_gen) end,
      done_fn: &(&1 < 1.01)
    )

    UI.set_wait(
      "Pressure Relief Vent 0#{loop}",
      "SHUT",
      fn -> !SteamGen.get_vent_open?(steam_gen) end,
      fn -> SteamGen.set_vent_open(steam_gen, false) end
    )
  end

  defp ping_remote do
    Node.self()
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> then(fn
      ["nonode", "nohost"] ->
        Mix.raise("This task must be run via `./task.sh auto_nuke.loop.stop <loop>`.")

      ["auto_nuke_loop_stop_" <> _, host] ->
        remote = :"nuke@#{host}"

        case Node.ping(remote) do
          :pong -> remote
          :pang -> Mix.raise("Cannot contact #{inspect(remote)}.  Is `./start.sh` running?")
        end
    end)
  end
end
