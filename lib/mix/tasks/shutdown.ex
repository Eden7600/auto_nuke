defmodule Mix.Tasks.AutoNuke.Shutdown do
  @moduledoc "Stop the entire reactor"
  @shortdoc "Stop the reactor"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias Mix.Tasks.AutoNuke.Startup

  @loops 1..3

  @remote_operators %{
    core_factor: {AutoNuke.Operator.CoreFactor, "Core Factor Operator"},
    core_temp: {AutoNuke.Operator.CoreTemp, "Core Temperature Operator"},
    steam_flow: {AutoNuke.Operator.SteamFlow, "Steam Flow Operator"},
    vacuum_tank: {AutoNuke.Operator.VacuumTank, "Vacuum Tank Operator"}
  }

  def run([]) do
    node = ping_remote()

    {:ok, _} = Application.ensure_all_started([:pubsub, :req])
    UI.log_to_file("startup.log")

    {:ok, _} = PubSub.start_link()
    {:ok, _} = AutoNuke.Ticker.start_link()

    Startup.enable_resistor_bank()
    open_breakers()

    disable_remotes(node, [:core_factor, :core_temp, :steam_flow])
    insert_control_rods()
    set_full_bypass()
    set_max_pump_speed()

    wait_for_low_steam()
    disable_remotes(node, [:vacuum_tank])
    stop_vacuum_pump()
    dump_steam_generator_pressure()

    wait_core_cooldown()
    stop_pressurizer()
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

    set_and_forget(
      name: "Control Rod Height",
      action: "SET TO 100.0",
      value: 100.0,
      get: &get_rods/0,
      put: &set_rods/1
    )
  end

  defp set_full_bypass do
    UI.console("Generation & Distribution")

    @loops
    |> Enum.each(fn loop ->
      set_and_forget(
        loop: loop,
        name: "Turbine Bypass 0#{loop}",
        value: 100,
        get: &get_bypass/1,
        put: &set_bypass/2
      )
    end)

    UI.console("Steam Generator")

    @loops
    |> Enum.each(fn loop ->
      set_and_forget(
        loop: loop,
        name: "Main Steam Control Valve 0#{loop}",
        value: 0,
        get: &get_mscv/1,
        put: &set_mscv/2
      )
    end)
  end

  defp set_max_pump_speed do
    UI.console("Coolant System")

    @loops
    |> Enum.each(fn loop ->
      set_and_forget(
        loop: loop,
        name: "Circulation Pump 0#{loop}",
        action: "SET TO 100",
        value: 100,
        get: &get_primary_pump/1,
        put: &set_primary_pump/2
      )
    end)
  end

  defp wait_for_low_steam do
    UI.console("Steam Generator")

    UI.wait(
      "Generators Steam Out",
      "WAIT FOR <50 kg/min COMBINED",
      fn ->
        @loops
        |> Enum.map(&get_steam_outlet/1)
        |> Enum.sum()
        |> Kernel.<=(50)
      end
    )
  end

  defp dump_steam_generator_pressure do
    UI.console("Steam Generator")

    @loops
    |> Enum.each(fn loop ->
      UI.set_wait(
        "Pressure Relief Vent 0#{loop}",
        "OPEN",
        fn -> get_vent_open?(loop) end,
        fn -> set_vent_open(loop, true) end
      )
    end)

    @loops
    |> Enum.each(fn loop ->
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
    delta = (initial - 100) |> ceil()

    UI.progress_loop(
      label: "Primary Temperature",
      fetch: fn -> (initial - get_core_temp()) |> ceil() end,
      max: delta
    )

    UI.wait("Status", "WAIT FOR BELOW CRITICAL MASS", fn ->
      !API.get_boolean("CORE_CRITICAL_MASS_REACHED")
    end)
  end

  defp stop_pressurizer do
    UI.console("Pressurizer")
    UI.set("Heating Power", "OFF")
    UI.set("Thermostat", "OFF")

    valve = "Valvula_Pressurizer_Spray"

    UI.set_wait(
      "PZR Cooling Valve",
      "OPEN",
      fn -> get_actuator(valve) == "OPEN" end,
      fn -> set_actuator(valve, "OPEN") end
    )
  end

  defp set_and_forget(opts) do
    {loop, opts} = Keyword.pop(opts, :loop)
    {name, opts} = Keyword.pop!(opts, :name)
    {action, opts} = Keyword.pop(opts, :action)
    {value, opts} = Keyword.pop!(opts, :value)
    {get_fn, opts} = Keyword.pop!(opts, :get)
    {put_fn, opts} = Keyword.pop!(opts, :put)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    {get_fn, put_fn} =
      case loop do
        nil ->
          {get_fn, put_fn}

        l when l in @loops ->
          {
            fn -> get_fn.(l) end,
            fn v -> put_fn.(l, v) end
          }
      end

    initial = get_fn.()

    action =
      action ||
        case value do
          0 -> "CLOSE"
          100 -> "OPEN"
          n -> "LIMITED (#{n}%)"
        end

    if initial == value do
      UI.wait(name, action, fn -> true end)
    else
      UI.set_wait(
        name,
        action,
        fn -> get_fn.() != initial end,
        fn -> put_fn.(value) end
      )
    end
  end

  defp ping_remote do
    Node.self()
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> then(fn
      ["nonode", "nohost"] ->
        Mix.raise("This task must be run via `./task.sh auto_nuke.loop.stop <loop>`.")

      ["auto_nuke_shutdown", host] ->
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

  defp get_core_temp, do: API.get_float("CORE_TEMP")

  defp get_steam_outlet(loop), do: API.get_float("STEAM_GEN_#{loop - 1}_OUTLET")
  defp get_pressure(loop), do: API.get_float("COOLANT_SEC_#{loop - 1}_PRESSURE")
  defp get_mscv(loop), do: API.get_float("MSCV_#{loop - 1}_OPENING_ACTUAL")
  defp set_mscv(loop, value), do: API.put("MSCV_#{loop - 1}_OPENING_ORDERED", value)
  defp get_bypass(loop), do: API.get_float("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL") |> round()
  defp set_bypass(loop, value), do: API.put("STEAM_TURBINE_#{loop - 1}_BYPASS_ORDERED", value)

  defp get_vent_open?(loop), do: API.get_boolean("STEAM_GEN_#{loop - 1}_VENT_SWITCH")
  defp set_vent_open(loop, open), do: API.put("STEAM_GEN_#{loop - 1}_VENT_SWITCH", open)

  defp get_rods, do: API.get_float("RODS_POS_ACTUAL")
  defp set_rods(value), do: API.put("RODS_ALL_POS_ORDERED", value)

  defp get_primary_pump(loop),
    do: API.get_float("COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_SPEED")

  defp set_primary_pump(loop, v),
    do: API.put("COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", v)

  defp valve_data(key) do
    API.get_json("VALVE_PANEL_JSON")
    |> Map.fetch!("valves")
    |> Map.fetch!(key)
  end

  defp get_actuator(key), do: valve_data(key) |> Map.fetch!("Actuator")
  defp set_actuator(key, action), do: API.put("VALVE_#{action}", key)
end
