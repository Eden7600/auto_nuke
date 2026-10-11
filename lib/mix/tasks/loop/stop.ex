defmodule Mix.Tasks.AutoNuke.Loop.Stop do
  @moduledoc "Stop a single loop in a running reactor"
  @shortdoc "Stop a loop"

  use Mix.Task

  alias AutoNuke.API
  alias AutoNuke.API.SteamGen
  alias AutoNuke.Operator.CoreTemp
  alias AutoNuke.Operator.PrimaryPumps
  alias AutoNuke.Operator.SteamFlow
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator.ResistorBanks
  alias Mix.Tasks.AutoNuke.Startup

  def run([loop]) do
    loop
    |> UI.parse_loop()
    |> stop()
  end

  @loop_emoji "\u{1F501}"

  def stop(loop) do
    remote_node = AutoNuke.PlantNode.find("auto_nuke.loop.stop <loop>")
    steam_flow_pid = {SteamFlow, remote_node}
    core_temp_pid = {CoreTemp, remote_node}
    primary_pumps_pid = {PrimaryPumps, remote_node}
    steam_gen = SteamGen.for_loop(loop)

    UI.init()
    IO.puts("#{@loop_emoji} Stopping loop #{loop} #{@loop_emoji}")
    UI.log_to_file("startup.log")

    # The ResistorBanks operator would fight the resistor bank handling below,
    # so stand it down for the duration of this task if it's running.
    resistor_banks_was_running = suspend_resistor_banks_operator(remote_node)

    Startup.enable_resistor_bank()

    UI.tablet("AutoNuke Remote Control")

    # Remove the loop from the automatic operators first so they stop
    # controlling it while the manual shutdown sequence is running.
    UI.set_wait(
      "Core Temperature Operator",
      "REMOVE LOOP #{loop}",
      fn -> loop not in CoreTemp.get_loops(core_temp_pid) end,
      fn -> CoreTemp.remove_loop(loop, core_temp_pid) end
    )

    UI.set_wait(
      "Steam Flow Operator",
      "REMOVE LOOP #{loop}",
      fn -> loop not in SteamFlow.get_loops(steam_flow_pid) end,
      fn -> SteamFlow.remove_loop(loop, steam_flow_pid) end
    )

    # The primary pump operator would otherwise keep driving this loop's pump.
    UI.set_wait(
      "Primary Pumps Operator",
      "REMOVE LOOP #{loop}",
      fn -> loop not in PrimaryPumps.get_loops(primary_pumps_pid) end,
      fn -> PrimaryPumps.remove_loop(loop, primary_pumps_pid) end
    )

    UI.wait("Turbine 0#{loop} Circuit Breaker", "OPEN", fn ->
      API.get_boolean("GENERATOR_#{loop - 1}_BREAKER")
    end)

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

    if resistor_banks_was_running, do: resume_resistor_banks_operator(remote_node)
  end

  defp suspend_resistor_banks_operator(node) do
    running? = :erpc.call(node, Process, :whereis, [ResistorBanks]) |> is_pid()

    if running? do
      UI.tablet("AutoNuke Remote Control")

      UI.set_wait(
        "Resistor Banks Operator",
        "DISABLE",
        fn -> :erpc.call(node, Process, :whereis, [ResistorBanks]) |> is_nil() end,
        fn -> :erpc.call(node, AutoNuke.Tui.Operators, :disable, [ResistorBanks]) end
      )
    end

    running?
  end

  defp resume_resistor_banks_operator(node) do
    UI.tablet("AutoNuke Remote Control")

    UI.set_wait(
      "Resistor Banks Operator",
      "ENABLE",
      fn -> :erpc.call(node, Process, :whereis, [ResistorBanks]) |> is_pid() end,
      fn -> :erpc.call(node, AutoNuke.Tui.Operators, :enable, [ResistorBanks]) end
    )
  end
end
