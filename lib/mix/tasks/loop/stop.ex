defmodule Mix.Tasks.AutoNuke.Loop.Stop do
  @moduledoc "Stop a single loop in a running reactor"
  @shortdoc "Stop a loop"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator.SteamFlow
  alias Mix.Tasks.AutoNuke.Loop.Start
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

    {:ok, _} = Application.ensure_all_started([:pubsub, :req])
    IO.puts("#{@loop_emoji} Stopping loop #{loop} #{@loop_emoji}")
    UI.log_to_file("startup.log")

    {:ok, _} = PubSub.start_link()
    {:ok, _} = AutoNuke.Ticker.start_link()

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

    Start.change_valve(
      loop: loop,
      name: "Turbine Bypass 0#{loop}",
      short_name: "Bypass 0#{loop}",
      target: 100,
      get: &get_bypass/1,
      put: &set_bypass/2
    )

    UI.console("Steam Generator")

    Start.change_valve(
      loop: loop,
      name: "Main Steam Control Valve 0#{loop}",
      short_name: "MSCV 0#{loop}",
      target: 0,
      get: &get_mscv/1,
      put: &set_mscv/2
    )

    UI.console("Coolant System")

    UI.wait(
      "Circulation Pump 0#{loop}",
      "OFF",
      fn -> API.get_float("COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_SPEED") == 0 end
    )

    UI.console("Steam Generator")

    UI.set_wait(
      "Pressure Relief Vent 0#{loop}",
      "OPEN",
      fn -> get_vent_open?(loop) end,
      fn -> set_vent_open(loop, true) end
    )

    UI.wait(
      "Generator 0#{loop} Pressure",
      "WAIT FOR 1 BAR",
      fn -> get_pressure(loop) == 1 end
    )

    UI.set_wait(
      "Pressure Relief Vent 0#{loop}",
      "SHUT",
      fn -> !get_vent_open?(loop) end,
      fn -> set_vent_open(loop, false) end
    )
  end

  defp ping_remote do
    Node.self()
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> then(fn
      ["nonode", "nohost"] ->
        Mix.raise("This task must be run via `./task.sh auto_nuke.loop.stop <loop>`.")

      ["auto_nuke_loop_stop", host] ->
        remote = :"nuke@#{host}"

        case Node.ping(remote) do
          :pong -> remote
          :pang -> Mix.raise("Cannot contact #{inspect(remote)}.  Is `./start.sh` running?")
        end
    end)
  end

  defp get_pressure(loop), do: API.get_float("COOLANT_SEC_#{loop - 1}_PRESSURE")
  defp get_mscv(loop), do: API.get_float("MSCV_#{loop - 1}_OPENING_ACTUAL")
  defp set_mscv(loop, value), do: API.put("MSCV_#{loop - 1}_OPENING_ORDERED", value)
  defp get_bypass(loop), do: API.get_float("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL") |> round()
  defp set_bypass(loop, value), do: API.put("STEAM_TURBINE_#{loop - 1}_BYPASS_ORDERED", value)

  defp get_vent_open?(loop), do: API.get_boolean("STEAM_GEN_#{loop - 1}_VENT_SWITCH")
  defp set_vent_open(loop, open), do: API.put("STEAM_GEN_#{loop - 1}_VENT_SWITCH", open)
end
