defmodule Mix.Tasks.AutoNuke.Shutdown do
  @moduledoc "Stop the entire reactor"
  @shortdoc "Stop the reactor"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.API.SteamGen
  alias AutoNuke.TaskUI, as: UI
  alias Mix.Tasks.AutoNuke.Startup

  @loops 1..3
  @steam_gens SteamGen.all()
  @primary_pumps @loops |> Enum.map(&API.Pumps.primary/1)
  @secondary_pumps @loops |> Enum.map(&API.Pumps.secondary/1)
  @condenser_cooling API.Pumps.condenser_cooling()
  @core API.Vessels.core_vessel()

  @remote_operators %{
    auto_drift: {AutoNuke.Operator.AutoDrift, "Automatic Drift Operator"},
    core_factor: {AutoNuke.Operator.CoreFactor, "Core Factor Operator"},
    core_temp: {AutoNuke.Operator.CoreTemp, "Core Temperature Operator"},
    steam_flow: {AutoNuke.Operator.SteamFlow, "Steam Flow Operator"},
    vacuum_tank: {AutoNuke.Operator.VacuumTank, "Vacuum Tank Operator"},
    condenser_cooling: {AutoNuke.Operator.CondenserCooling, "Condenser Cooling Operator"}
  }

  def run([]) do
    node = ping_remote()

    UI.init()
    UI.log_to_file("startup.log")

    Startup.enable_resistor_bank()
    open_breakers()
    set_shutdown_mode()

    disable_remotes(node, [:auto_drift, :core_factor, :core_temp, :steam_flow])
    insert_control_rods()
    set_full_bypass()
    set_max_pump_speed()

    wait_for_low_steam()
    disable_remotes(node, [:vacuum_tank])
    stop_vacuum_pump()
    dump_steam_generator_pressure()

    wait_core_cooldown()
    stop_pressurizer()

    disable_remotes(node, [:condenser_cooling])
    stop_all_pumps()
    disable_resistor_banks()
  end

  defp open_breakers do
    UI.console("Generation & Distribution")

    @loops
    |> Enum.each(fn loop ->
      UI.wait("Turbine 0#{loop} Circuit Breaker", "OPEN", fn ->
        API.get_boolean("GENERATOR_#{loop - 1}_BREAKER")
      end)
    end)
  end

  defp set_shutdown_mode do
    UI.console("Fuel")

    UI.set_wait(
      "Operating Mode",
      "SHUTDOWN",
      fn -> API.get_string("CORE_OPERATION_MODE") == "SHUTDOWN" end,
      fn -> API.put("CORE_OPERATION_MODE", "SHUTDOWN") end
    )
  end

  defp disable_remotes(node, remotes) do
    UI.tablet("AutoNuke Remote Control")

    remotes
    |> Enum.each(fn key ->
      {module, name} = @remote_operators |> Map.fetch!(key)

      UI.set_wait(
        name,
        "DISABLE",
        remote_fn(node, fn ->
          !(Process.whereis(module) in PubSub.subscribers(:ticker))
        end),
        remote_fn(node, fn ->
          PubSub.unsubscribe(module, :ticker)
        end)
      )
    end)
  end

  defp insert_control_rods do
    UI.console("Reactor Core")

    # The min is in case they're already set to 100.
    initial = get_rods() |> min(99.9)

    UI.set_wait(
      "Control Rod Height",
      "SET TO 100.0",
      fn -> get_rods() != initial end,
      fn -> set_rods(100.0) end
    )
  end

  defp set_full_bypass do
    UI.console("Generation & Distribution")
    @steam_gens |> Enum.each(fn sg -> sg.bypass |> UI.Valves.set(100, wait: false) end)

    UI.console("Steam Generator")
    @steam_gens |> Enum.each(fn sg -> sg.mscv |> UI.Valves.set(0, wait: false) end)
  end

  defp set_max_pump_speed do
    UI.console("Coolant System")

    @primary_pumps
    |> Enum.each(fn pump ->
      if API.Pumps.get_active?(pump) do
        UI.Pumps.set_speed(pump, 49, wait: false)
      end
    end)
  end

  defp wait_for_low_steam do
    UI.console("Steam Generator")

    steam_out = SteamGen.get_total_outlet()

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(max(steam_out, 50), min(steam_out, 50), " kg/min", 1),
      label: "Total Steam",
      current_fn: &SteamGen.get_total_outlet/0,
      done_fn: &(&1 <= 50)
    )
  end

  defp dump_steam_generator_pressure do
    UI.console("Steam Generator")

    @steam_gens
    |> Enum.each(fn steam_gen ->
      temp = SteamGen.get_temperature(steam_gen)

      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.target(max(temp, 100), 50, "°C", 1),
        label: "Temperature",
        current_fn: fn -> SteamGen.get_temperature(steam_gen) end,
        done_fn: &(&1 <= 50)
      )
    end)

    @steam_gens
    |> Enum.each(fn steam_gen ->
      UI.set_wait(
        "Pressure Relief Vent 0#{steam_gen.loop}",
        "OPEN",
        fn -> SteamGen.get_vent_open?(steam_gen) end,
        fn -> SteamGen.set_vent_open(steam_gen, true) end
      )
    end)

    @steam_gens
    |> Enum.each(fn steam_gen ->
      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.target(70, 1, " bar", 1),
        label: "Pressure",
        current_fn: fn -> SteamGen.get_pressure(steam_gen) end,
        done_fn: &(&1 < 1.01)
      )
    end)

    @steam_gens
    |> Enum.each(fn steam_gen ->
      UI.set_wait(
        "Pressure Relief Vent 0#{steam_gen.loop}",
        "SHUT",
        fn -> !SteamGen.get_vent_open?(steam_gen) end,
        fn -> SteamGen.set_vent_open(steam_gen, false) end
      )
    end)
  end

  defp stop_vacuum_pump do
    UI.console("Condenser")

    UI.set_wait(
      "Vacuum Pump",
      "OFF",
      fn -> !API.get_boolean("CONDENSER_VACUUM_PUMP_ACTIVE") end,
      fn -> API.put("CONDENSER_VACUUM_PUMP_START_STOP", "STOP") end
    )
  end

  defp wait_core_cooldown do
    UI.console("Reactor Core")

    UI.set("Internal Temperature", "COOL TO 100°C")

    initial = get_core_temp()
    target = 100

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(initial, target, "°C"),
      label: "Core Temp",
      current_fn: &get_core_temp/0,
      done_fn: &(&1 <= target)
    )

    UI.wait("Status", "WAIT FOR BELOW CRITICAL MASS", fn ->
      !API.get_boolean("CORE_CRITICAL_MASS_REACHED")
    end)
  end

  defp stop_pressurizer do
    UI.console("Pressurizer")
    API.Valves.pzr_cooling() |> UI.Valves.open()

    UI.set("Heating Power", "OFF")
    UI.set("Thermostat", "OFF")

    start_pressure = API.Vessels.get_pressure(@core) |> ceil()

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(max(start_pressure, 160), 1, "bar", 1),
      label: "Core Pressure",
      current_fn: fn -> API.Vessels.get_pressure(@core) end,
      done_fn: &(&1 <= 1.1)
    )
  end

  defp stop_all_pumps do
    UI.console("Coolant System")
    @primary_pumps |> Enum.each(&UI.Pumps.stop/1)

    UI.console("Steam Generator")
    @secondary_pumps |> Enum.each(&UI.Pumps.stop/1)

    UI.console("Condenser")
    @condenser_cooling |> UI.Pumps.stop()
  end

  def disable_resistor_banks do
    UI.console("Generation & Distribution")

    UI.set_wait(
      "Resistor Bank Main Switch",
      "OFF",
      fn -> !API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH") end,
      fn -> API.put("RESISTOR_BANKS_MAIN_SWITCH", false) end
    )

    1..4
    |> Enum.each(fn bank ->
      UI.set_wait(
        "Resistor Bank Switch 0#{bank}",
        "OFF",
        fn -> !API.get_boolean("RESISTOR_BANK_0#{bank}_SWITCH") end,
        fn -> API.put("RESISTOR_BANK_0#{bank}_SWITCH", false) end
      )
    end)

    UI.notice("Reminder: Transformers may need to be disabled for maintenance.")
  end

  defp ping_remote do
    Node.self()
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> then(fn
      ["nonode", "nohost"] ->
        Mix.raise("This task must be run via `./task.sh auto_nuke.loop.stop <loop>`.")

      ["auto_nuke_shutdown_" <> _, host] ->
        remote = :"nuke@#{host}"

        case Node.ping(remote) do
          :pong -> remote
          :pang -> Mix.raise("Cannot contact #{inspect(remote)}.  Is `./start.sh` running?")
        end
    end)
  end

  defp remote_fn(node, fun), do: fn -> remote(node, fun) end

  defp remote(node, fun) do
    me = self()
    ref = make_ref()
    Node.spawn_link(node, fn -> send(me, {:remote, ref, fun.()}) end)

    receive do
      {:remote, ^ref, result} -> result
    end
  end

  defp get_core_temp, do: @core |> API.Vessels.get_temperature()

  defp get_rods, do: API.get_float("RODS_POS_ACTUAL")
  defp set_rods(value), do: API.put("RODS_ALL_POS_ORDERED", value)
end
