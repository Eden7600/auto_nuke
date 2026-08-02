defmodule AutoNuke.Tui.Data do
  @moduledoc """
  Builds the dashboard's data snapshot.

  Every value is fetched through `safe/1`: a failed read (game unreachable,
  variable missing, operator not running) yields `:err` for that field
  instead of crashing the TUI. Reads go through `AutoNuke.API`, which is
  memoized per game tick, so the dashboard shares HTTP requests with any
  running operators.
  """

  alias AutoNuke.API
  alias AutoNuke.Operator, as: Op

  # Operator GenServer queries must never stall a frame.
  @call_timeout 250

  @tank_vessels [
    {"Primary CST", API.Vessels.primary_cst()},
    {"Core Pool", API.Vessels.core_pool()},
    {"Pool Storage", API.Vessels.core_pool_storage()},
    {"Reservoir", API.Vessels.reservoir()},
    {"Boric Acid", API.Vessels.boric_acid()},
    {"NaOH", API.Vessels.sodium_hydroxide()},
    {"Diesel", API.Vessels.diesel_fuel()}
  ]

  def fetch do
    # Preflight: one cheap read decides reachability, so an offline game
    # costs one connection attempt instead of one per field.
    case safe(fn -> API.get_float("CORE_TEMP") end) do
      :err -> empty()
      _ -> fetch_all()
    end
  end

  defp fetch_all do
    %{
      time: safe(fn -> API.Misc.get_time_stamp() |> AutoNuke.Time.timestamp_to_string() end),
      sim_speed: safe(fn -> API.get_integer("GAME_SIM_SPEED") end),
      power: power(),
      core: core(),
      pzr: pzr(),
      loops: Enum.map(1..3, &loop_row/1),
      condenser: condenser(),
      tanks: tanks(),
      operators: operators(),
      demand: safe_call(Op.SteamFlow, :get_demand_status),
      health: health(),
      overrides: overrides()
    }
  end

  @doc """
  Every override/boost/non-default mode currently active on a running
  operator, as `%{op: label, desc: description}`. Local GenServer queries
  only — works even when the game is unreachable.
  """
  def overrides do
    [
      steam_flow_override(),
      boost("SteamFlow", safe_call(Op.SteamFlow, :get_boost_mode)),
      core_temp_override(),
      rods_mode(),
      boost("SecondaryFill L1", secondary_boost(1)),
      boost("SecondaryFill L2", secondary_boost(2)),
      boost("SecondaryFill L3", secondary_boost(3)),
      boost("CondenserFill", safe_call(Op.CondenserFill, :get_boost_mode)),
      boost("CondenserCooling", safe_call(Op.CondenserCooling, :get_boost_mode))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp steam_flow_override do
    case safe_call(Op.SteamFlow, :get_override) do
      {{ratio, :ratio}, expiry} -> %{op: "SteamFlow", desc: "→ #{round(ratio * 100)}%#{expiry(expiry)}"}
      {{mw, :mw}, expiry} -> %{op: "SteamFlow", desc: "→ #{mw} MW#{expiry(expiry)}"}
      _ -> nil
    end
  end

  defp core_temp_override do
    case safe_call(Op.CoreTemp, :get_override) do
      {temp, expiry} -> %{op: "CoreTemp", desc: "→ #{temp}°C#{expiry(expiry)}"}
      _ -> nil
    end
  end

  # :direct is the hands-on mode; :predictive is the default.
  defp rods_mode do
    case safe_call(Op.ControlRods, :get_mode) do
      :direct -> %{op: "ControlRods", desc: "direct mode"}
      _ -> nil
    end
  end

  defp secondary_boost(loop) do
    safe_call(Module.concat(Op.SecondaryFill, "L#{loop}"), :get_boost_mode)
  end

  defp boost(_label, value) when value in [nil, :err], do: nil
  defp boost(label, expiry), do: %{op: label, desc: "boost#{expiry(expiry)}"}

  defp expiry(:never), do: " (no expiry)"
  defp expiry(ts) when is_integer(ts), do: " until #{AutoNuke.Time.timestamp_to_string(ts)}"

  defp health do
    %{
      integrity: safe(fn -> API.get_float("CORE_INTEGRITY") end),
      wear: safe(fn -> API.get_float("CORE_WEAR") end),
      issues: safe(fn -> health_issues() end)
    }
  end

  # Anything listed here is a problem; healthy plants return [].
  defp health_issues do
    []
    |> add_issue("MELTDOWN IMMINENT", fn -> API.get_boolean("CORE_IMMINENT_FUSION") end)
    |> add_issue("Alarms active", fn -> flagged?("ALARMS_ACTIVE") end)
    |> add_issue("Rods deformed", fn -> flagged?("RODS_DEFORMED") end)
    |> add_issue("Rods misaligned", fn -> API.get_string("RODS_ALIGNED") not in ["-1", "True"] end)
    |> add_issue("Condenser pump overload", fn ->
      API.get_boolean("CONDENSER_CIRCULATION_PUMP_OVERLOAD_STATUS")
    end)
    |> add_issue("Em. generator 1 maintenance", fn ->
      API.get_boolean("EMERGENCY_GENERATOR_1_MAINTENANCE_NEEDED")
    end)
    |> add_issue("Em. generator 2 maintenance", fn ->
      API.get_boolean("EMERGENCY_GENERATOR_2_MAINTENANCE_NEEDED")
    end)
    |> Enum.reverse()
    |> Kernel.++(safe_list(&panel_issues/0))
  end

  # Per-device failure flags from the valve panel (one request, shared with
  # the pump/valve modules via memoization).
  @panel_flags ~w(Stuck Overload Dry MaintenanceRequired Destroyed Flooded)

  defp panel_issues do
    panel = API.get_json("VALVE_PANEL_JSON")

    for section <- ["pumps", "valves"],
        {name, entry} <- Map.get(panel, section, %{}),
        state = Map.get(entry, "State", %{}),
        flag <- @panel_flags,
        state[flag] == true do
      "#{name}: #{flag}"
    end
  end

  defp safe_list(fun) do
    case safe(fun) do
      :err -> []
      list -> list
    end
  end

  defp add_issue(issues, label, check) do
    case safe(check) do
      true -> [label | issues]
      _ -> issues
    end
  end

  # Some warning variables return empty / "False" / "0" when healthy and
  # text when not.
  defp flagged?(key) do
    API.get_string(key) not in ["", "False", "0", "-1"]
  end

  @doc """
  The all-unreadable snapshot: same shape as `fetch/0` with every plant
  value `:err`. Operator status is still live (it's local, no HTTP).
  """
  def empty do
    %{
      time: :err,
      sim_speed: :err,
      power: %{gen_kw: :err, demand_mw: :err, supply: :err},
      core: %{
        temp: :err,
        target: :err,
        rods: Enum.map(1..9, &{&1, :err}),
        boron_ppm: :err,
        fill: :err
      },
      pzr: %{temp: :err, pressure: :err, heaters: :err},
      loops:
        Enum.map(1..3, fn loop ->
          %{
            loop: loop,
            sg_temp: :err,
            sg_pressure: :err,
            outlet: :err,
            gen_kw: :err,
            gen_hz: :err,
            connected: :err
          }
        end),
      condenser: %{fill: :err, temp: :err, vacuum: :err, vac_active: :err, retention: :err},
      tanks: Enum.map(@tank_vessels, fn {label, _vessel} -> {label, :err} end),
      operators: operators(),
      demand: :err,
      health: %{integrity: :err, wear: :err, issues: :err},
      # Override state is local process state — live even when offline.
      overrides: overrides()
    }
  end

  defp power do
    %{
      gen_kw: safe(fn -> total_generation_kw() end),
      demand_mw: safe(fn -> API.Power.get_demand_mw() end),
      supply: safe(fn -> supply_source() end)
    }
  end

  # Actual generation: what the (connected) turbine generators produce.
  # (POWER_FROM_TURBINE_KW is the plant's own draw, not grid output.)
  defp total_generation_kw do
    1..3
    |> Enum.map(fn loop -> safe(fn -> API.Generator.get_power_kw(loop) end) end)
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  # Where the plant's internal supply comes from (same checks as startup's
  # power-source test), worst case first.
  defp supply_source do
    cond do
      API.get_float("EMERGENCY_BATTERIES_POWER_OUTPUT_KW") > 0.0 -> :batteries
      API.get_float("EMERGENCY_GENERATOR_POWER_OUTPUT_KW") > 0.0 -> :diesel
      API.Power.get_external_used_kw() > 0.0 -> :external
      true -> :self
    end
  end

  @core_vessel API.Vessels.core_vessel()

  defp core do
    %{
      temp: safe(fn -> API.Vessels.get_temperature(@core_vessel) end),
      target: safe_call(Op.ControlRods, :get_target),
      rods: Enum.map(1..9, &{&1, safe(fn -> rod_position(&1) end)}),
      boron_ppm: safe(fn -> API.get_float("CHEM_BORON_PPM") end),
      fill: safe(fn -> API.Vessels.get_fill_gauge(@core_vessel) end)
    }
  end

  defp rod_position(bank), do: API.get_float_or_nil("ROD_BANK_POS_#{bank - 1}_ACTUAL")

  defp pzr do
    %{
      temp: safe(fn -> API.Pzr.get_temperature() end),
      pressure: safe(fn -> API.Pzr.get_pressure() end),
      heaters: safe(fn -> API.Pzr.get_heat_enabled?() end)
    }
  end

  defp loop_row(loop) do
    sg = API.SteamGen.for_loop(loop)

    %{
      loop: loop,
      sg_temp: safe(fn -> API.SteamGen.get_temperature(sg) end),
      sg_pressure: safe(fn -> API.SteamGen.get_pressure(sg) end),
      outlet: safe(fn -> API.SteamGen.get_outlet(sg) end),
      gen_kw: safe(fn -> API.Generator.get_power_kw(loop) end),
      gen_hz: safe(fn -> API.Generator.get_hertz(loop) end),
      connected: safe(fn -> API.Generator.get_is_connected(loop) end)
    }
  end

  @condenser API.Vessels.condenser()
  @retention API.Vessels.retention_tank()

  defp condenser do
    %{
      fill: safe(fn -> API.Vessels.get_fill_percent(@condenser) end),
      temp: safe(fn -> API.Vessels.get_temperature(@condenser) end),
      vacuum: safe(fn -> API.VacuumPump.get_vacuum_level() end),
      vac_active: safe(fn -> API.VacuumPump.get_active?() end),
      retention: safe(fn -> API.Vessels.get_fill_percent(@retention) end)
    }
  end

  defp tanks do
    Enum.map(@tank_vessels, fn {label, vessel} ->
      {label, safe(fn -> API.Vessels.get_fill_percent(vessel) end)}
    end)
  end

  @operator_names [
    SteamFlow: Op.SteamFlow,
    CoreTemp: Op.CoreTemp,
    ControlRods: Op.ControlRods,
    PrimaryPumps: Op.PrimaryPumps,
    SecondaryFill: nil,
    VacuumTank: Op.VacuumTank,
    PCSTFill: Op.PCSTFill,
    CoreFill: Op.CoreFill,
    BoronLevel: Op.BoronLevel,
    CondenserFill: Op.CondenserFill,
    CondenserCooling: Op.CondenserCooling
  ]

  defp operators do
    Enum.map(@operator_names, fn
      {label, nil} -> {label, secondary_fill_status()}
      {label, module} -> {label, is_pid(Process.whereis(module))}
    end)
  end

  # SecondaryFill runs one process per loop, named SecondaryFill.L<loop>.
  defp secondary_fill_status do
    1..3
    |> Enum.map(&Process.whereis(Module.concat(Op.SecondaryFill, "L#{&1}")))
    |> Enum.count(&is_pid/1)
    |> case do
      0 -> false
      n -> {:count, n}
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp safe(fun) do
    try do
      fun.()
    rescue
      _ -> :err
    catch
      :exit, _ -> :err
    end
  end

  defp safe_call(name, message) do
    safe(fn ->
      case Process.whereis(name) do
        nil -> :err
        pid -> GenServer.call(pid, message, @call_timeout)
      end
    end)
  end
end
