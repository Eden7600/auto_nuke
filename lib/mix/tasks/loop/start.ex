defmodule Mix.Tasks.AutoNuke.Loop.Start do
  @moduledoc "Start a single loop in a running reactor"
  @shortdoc "Start a loop"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.ControlAxis
  alias AutoNuke.Operator.SteamFlow
  alias Mix.Tasks.AutoNuke.Startup

  # Control MSCV to maintain this much pressure:
  @target_pressure 60
  # Allow this range of MSCV settings:
  @mscv_range 2..20

  def run([loop]) do
    loop
    |> UI.parse_loop()
    |> startup()
  end

  @loop_emoji "\u{1F501}"

  def startup(loop) do
    remote_node = ping_remote()
    steam_flow_pid = {SteamFlow, remote_node}

    if loop in SteamFlow.get_loops(steam_flow_pid) do
      Mix.raise("Loop #{loop} is already active.")
    end

    {:ok, _} = Application.ensure_all_started([:pubsub, :req])
    IO.puts("#{@loop_emoji} Starting loop #{loop} #{@loop_emoji}")
    UI.log_to_file("startup.log")

    {:ok, _} = PubSub.start_link()
    {:ok, _} = AutoNuke.Ticker.start_link()

    Startup.enable_resistor_bank()
    close_valves(loop)
    Startup.start_secondary_circulation([loop])
    monitor_pressure(loop)
    Startup.start_primary_circulation([loop])
    Startup.connect_to_grid([loop], false)

    UI.tablet("AutoNuke Remote Control")

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

      ["auto_nuke_loop_start", host] ->
        remote = :"nuke@#{host}"

        case Node.ping(remote) do
          :pong -> remote
          :pang -> Mix.raise("Cannot contact #{inspect(remote)}.  Is `./start.sh` running?")
        end
    end)
  end

  defp monitor_pressure(loop) do
    spawn_link(fn ->
      PubSub.subscribe(self(), :ticker)

      ControlAxis.new(
        kp: -0.1,
        ki: -0.01,
        deadzone: 0.5,
        to_value_fn: &axis_to_mscv/1,
        offset: -1.0,
        initial_value: 0
      )
      |> pressure_loop(loop)
    end)
  end

  defp pressure_loop(axis, loop) do
    receive do
      {:tick, _} ->
        case ControlAxis.step(axis, @target_pressure, get_pressure(loop)) do
          {:changed, axis, new, old} ->
            Logger.debug("Changing MSCV from #{old} to #{new}.")
            set_mscv(loop, new)
            axis

          {:unchanged, axis, _old} ->
            axis
        end
        |> pressure_loop(loop)
    end
  end

  defp close_valves(loop) do
    UI.console("Steam Generator")

    UI.set_wait(
      "Pressure Relief Vent 0#{loop}",
      "OFF",
      fn -> !API.get_boolean("STEAM_GEN_#{loop - 1}_VENT_SWITCH") end,
      fn -> API.put("STEAM_GEN_#{loop - 1}_VENT_SWITCH", false) end
    )

    change_valve(
      loop: loop,
      name: "Main Steam Control Valve 0#{loop}",
      short_name: "MSCV 0#{loop}",
      target: @mscv_range.first,
      get: &get_mscv/1,
      put: &set_mscv/2
    )

    UI.console("Generation & Distribution")

    change_valve(
      loop: loop,
      name: "Turbine Bypass 0#{loop}",
      short_name: "Bypass 0#{loop}",
      target: 0,
      get: &get_bypass/1,
      put: &set_bypass/2
    )

    UI.console("Drain & Vent Valves")
    vent_key = "VALVULA_VENT_TURBINA_0#{loop}"

    change_valve(
      loop: loop,
      name: "Turbine #{letter(loop)} Vent",
      short_name: "Vent 0#{loop}",
      target: 0,
      get: fn _ -> get_valve_open_percent(vent_key) end,
      put: fn _, 0 -> set_actuator(vent_key, "CLOSE") end,
      final: %{
        verb: "OFF",
        check: fn -> get_actuator(vent_key) == "OFF" end,
        set: fn -> set_actuator(vent_key, "OFF") end
      }
    )
  end

  def change_valve(opts) do
    {loop, opts} = Keyword.pop!(opts, :loop)
    {name, opts} = Keyword.pop!(opts, :name)
    {short_name, opts} = Keyword.pop(opts, :short_name, name)
    {target, opts} = Keyword.pop!(opts, :target)
    {get_fn, opts} = Keyword.pop!(opts, :get)
    {put_fn, opts} = Keyword.pop!(opts, :put)
    {final, opts} = Keyword.pop(opts, :final)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    initial = get_fn.(loop)

    verb =
      case target do
        0 -> "CLOSE"
        100 -> "OPEN"
        n -> "LIMITED (#{n}%)"
      end

    if initial == target do
      UI.wait(name, verb, fn -> true end)
    else
      UI.set_wait(
        name,
        verb,
        fn -> get_fn.(loop) != initial end,
        fn -> put_fn.(loop, target) end
      )

      if target > initial do
        UI.progress_loop(
          label: short_name,
          fetch: fn -> get_fn.(loop) end,
          max: target
        )
      else
        UI.progress_loop(
          label: short_name,
          fetch: fn -> initial - get_fn.(loop) end,
          max: initial - target
        )
      end

      if final do
        UI.set_wait(
          name,
          final.verb,
          final.check,
          final.set
        )
      end
    end
  end

  @mscv_span (@mscv_range.last - @mscv_range.first) / 2
  defp axis_to_mscv(output), do: round((output + 1.0) * @mscv_span + @mscv_range.first)

  defp letter(1), do: "A"
  defp letter(2), do: "B"
  defp letter(3), do: "C"

  defp get_pressure(loop), do: API.get_float("COOLANT_SEC_#{loop - 1}_PRESSURE")
  defp get_mscv(loop), do: API.get_float("MSCV_#{loop - 1}_OPENING_ACTUAL")
  defp set_mscv(loop, value), do: API.put("MSCV_#{loop - 1}_OPENING_ORDERED", value)
  defp get_bypass(loop), do: API.get_float("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL") |> round()
  defp set_bypass(loop, value), do: API.put("STEAM_TURBINE_#{loop - 1}_BYPASS_ORDERED", value)

  defp valve_data(key) do
    API.get_json("VALVE_PANEL_JSON")
    |> Map.fetch!("valves")
    |> Map.fetch!(key)
  end

  defp get_actuator(key), do: valve_data(key) |> Map.fetch!("Actuator")
  defp get_valve_open_percent(key), do: valve_data(key) |> Map.fetch!("Value") |> round()

  defp set_actuator(key, action) do
    API.put("VALVE_#{action}", key)
  end
end
