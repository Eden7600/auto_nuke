defmodule Mix.Tasks.AutoNuke.Startup do
  @moduledoc "Start the reactor from scratch"
  @shortdoc "Start the reactor"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  # Target PPM for boron injection:
  @boron_target 2800
  # How carefully to inject boron (higher = more):
  @boron_easing 3
  # At easing of 3, we start slowing down when boron PPM is
  # within 150 of target, since 50 g/m * 3 = 150.
  # This should allow us to miss some data ticks (which shouldn't happen anyway)
  # and still safely stop at the target.

  # Set rods to this (%) to begin reaction:
  @startup_rods 90
  # Stop and maintain this temperature (°C):
  @startup_temp 280
  # Wait for this temperature before starting turbines:
  @min_temp 270
  # Open or close MSCV to this (%):
  @startup_mscv 5

  # Need at least this % in the retention tank before we start the vacuum pump:
  @retention_percent 45
  # The reason we don't use 50% is that we'll already have the retention tank
  # process running and targeting 50%, and it might linger around 49%.

  def run([]) do
    Application.put_env(:auto_nuke, :start, false)
    {:ok, _} = Application.ensure_all_started([:auto_nuke, :logger, :pubsub])
    UI.log_to_file("startup.log")

    {:ok, _} = PubSub.start_link()
    {:ok, _} = AutoNuke.Ticker.start_link()

    loops = get_installed_secondary_loops()

    check_power_source()
    start_pressurizer()
    start_primary_circulation(loops)
    begin_injecting_boron()
    start_condenser()
    open_steam_valves(loops)
    enable_resistor_bank()

    wait_before_load_fuel(loops)
    load_fuel()

    start_secondary_circulation(loops)

    loops
    |> Enum.each(fn loop ->
      {:ok, _} = AutoNuke.Operator.SecondaryFill.start_link(loop: loop)
    end)

    achieve_criticality()
    {:ok, _} = AutoNuke.Operator.CoreTemp.start_link(target: @startup_temp)

    start_vacuum_pump()
    {:ok, _} = AutoNuke.Operator.VacuumTank.start_link()

    wait_for_temperature(@min_temp)

    request_connection()
    start_turbine(loops)
    connect_to_grid(loops)
    {:ok, _} = AutoNuke.Operator.SteamFlow.start_link()

    UI.console("ALL")
    UI.wait("Operator", "TAKE OVER", fn -> false end)
  end

  defp check_power_source do
    UI.console("Internal Supply")

    cond do
      API.get_float("EMERGENCY_BATTERIES_POWER_OUTPUT_KW") > 0.0 ->
        UI.warn("Currently running on batteries.")
        UI.notice("Consider enabling external power, or starting one of the generators.")

      API.get_float("EMERGENCY_GENERATOR_POWER_OUTPUT_KW") > 0.0 ->
        UI.warn("Currently running on emergency generators.")
        UI.notice("Consider enabling external power, if available.")

      API.get_float("POWER_FROM_EXTERNAL_KW") > 0.0 ->
        UI.success("Currently running on external power.")

      true ->
        UI.warn("Can't figure out where power is coming from.")
    end
  end

  defp start_pressurizer do
    UI.console("Pressurizer")
    UI.set("Thermostat", "ON")
    UI.set("Heating Power", "ON")

    UI.wait("Heating Power Level", "set to HIGH", fn ->
      API.get_float("CORE_PRESSURE") > 1.0
    end)
  end

  defp start_primary_circulation(loops) do
    UI.console("Coolant System")

    start_pumps("CORE", "Circulation Pump", loops)

    key = fn loop -> "COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED" end
    get = fn loop -> key.(loop) |> API.get_float() |> round() end
    put = fn value, loop -> key.(loop) |> API.put(value) end

    UI.set_wait(
      "Primary Pump Speed",
      "MEDIUM (50%)",
      fn ->
        loops
        |> Enum.map(get)
        |> Enum.all?(&(&1 == 50))
      end,
      fn ->
        loops
        |> Enum.map(&put.(50, &1))
      end
    )
  end

  defp start_pumps(key, title, loops) do
    ordered_key = fn loop -> "COOLANT_#{key}_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED" end
    actual_key = fn loop -> "COOLANT_#{key}_CIRCULATION_PUMP_#{loop - 1}_SPEED" end

    get_ordered = fn loop -> ordered_key.(loop) |> API.get_float() |> round() end
    get_actual = fn loop -> actual_key.(loop) |> API.get_float() |> round() end
    put_ordered = fn value, loop -> ordered_key.(loop) |> API.put(value) end

    loops
    |> Enum.each(fn loop ->
      # Set pump to at least speed 1 (if not already higher).
      # This has to come before "pump on" because we can't tell the difference
      # between a pump that is off, and a pump that is on but set to zero.
      get_ordered.(loop)
      |> max(1)
      |> put_ordered.(loop)

      UI.wait("#{title} 0#{loop}", "ON", fn ->
        get_actual.(loop) > 0.9
      end)
    end)
  end

  defp start_condenser do
    UI.console("Condenser")

    UI.set_wait(
      "Cooling Pump",
      "ON",
      fn -> API.get_boolean("CONDENSER_CIRCULATION_PUMP_SWITCH") end,
      fn -> API.put("CONDENSER_CIRCULATION_PUMP_SWITCH", true) end
    )

    UI.set_wait(
      "Cooling Pump Speed",
      "MEDIUM (50%)",
      fn -> API.get_float("CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED") >= 50 end,
      fn -> API.put("CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED", 50) end
    )
  end

  defp set_all_mscv(loops, description, target) do
    loops
    |> Enum.each(fn loop ->
      index = loop - 1
      init_mscv = API.get_float("MSCV_#{index}_OPENING_ACTUAL")

      UI.set_wait_unless(
        "Main Steam Control Valve 0#{loop}",
        description,
        fn -> init_mscv == target end,
        fn -> API.get_float("MSCV_#{index}_OPENING_ACTUAL") != init_mscv end,
        fn -> API.put("MSCV_#{index}_OPENING_ORDERED", target) end
      )
    end)
  end

  defp set_all_bypass(loops, description, target) do
    loops
    |> Enum.each(fn loop ->
      index = loop - 1
      init_bypass = API.get_float("STEAM_TURBINE_#{index}_BYPASS_ACTUAL")

      UI.set_wait_unless(
        "Turbine Bypass Valve 0#{loop}",
        description,
        fn -> init_bypass == target end,
        fn -> API.get_float("STEAM_TURBINE_#{index}_BYPASS_ACTUAL") != init_bypass end,
        fn -> API.put("STEAM_TURBINE_#{index}_BYPASS_ORDERED", target) end
      )
    end)
  end

  defp open_steam_valves(loops) do
    UI.console("Steam Generator")
    set_all_mscv(loops, "CLOSED (0%)", 0)

    UI.console("Generation & Distribution")
    set_all_bypass(loops, "OPEN (100%)", 100)

    UI.console("Condenser")

    UI.set_wait(
      "Startup Motive Steam Inlet",
      "OPEN (100%)",
      fn -> API.get_float("STEAM_EJECTOR_STARTUP_MOTIVE_VALVE_ORDERED") >= 100 end,
      fn -> API.put("STEAM_EJECTOR_STARTUP_MOTIVE_VALVE", 100) end
    )

    UI.set_wait(
      "Operational Motive Steam Inlet",
      "CLOSED (0%)",
      fn -> API.get_float("STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE_ORDERED") <= 0 end,
      fn -> API.put("STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE", 0) end
    )

    UI.set_wait(
      "Condensate Return Valve",
      "CLOSED (0%)",
      fn -> API.get_float("STEAM_EJECTOR_CONDENSER_RETURN_VALVE_ORDERED") <= 0 end,
      fn -> API.put("STEAM_EJECTOR_CONDENSER_RETURN_VALVE", 0) end
    )
  end

  defp request_connection do
    UI.tablet("Communications Center")
    UI.set("Start Operations", "REQUEST")
    IO.gets("Press enter when permission requested ...")
  end

  defp wait_before_load_fuel(loops) do
    UI.console("Coolant System")

    loops
    |> Enum.each(fn loop ->
      UI.progress_loop(
        label: "Pump 0#{loop} Speed",
        fetch: fn ->
          API.get_float("COOLANT_CORE_CIRCULATION_PUMP_#{loop - 1}_SPEED")
          |> floor()
        end,
        max: 50
      )
    end)

    UI.console("Condenser")

    UI.progress_loop(
      label: "Pump Speed",
      fetch: fn -> API.get_float("CONDENSER_CIRCULATION_PUMP_SPEED") |> floor() end,
      max: 50
    )

    UI.progress_loop(
      label: "SMSI",
      fetch: fn -> API.get_float("STEAM_EJECTOR_STARTUP_MOTIVE_VALVE_ACTUAL") |> floor() end,
      max: 100
    )

    UI.progress_loop(
      label: "OMSI",
      fetch: fn ->
        (100 - API.get_float("STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE_ACTUAL"))
        |> floor()
      end,
      max: 100
    )

    UI.progress_loop(
      label: "CRV",
      fetch: fn ->
        (100 - API.get_float("STEAM_EJECTOR_CONDENSER_RETURN_VALVE_ACTUAL"))
        |> floor()
      end,
      max: 100
    )

    UI.console("Steam Generator")

    loops
    |> Enum.each(fn loop ->
      UI.progress_loop(
        label: "MSCV 0#{loop}",
        fetch: fn ->
          # Hack to support the fact that progress bars must be ascending:
          (100 - API.get_float("MSCV_#{loop - 1}_OPENING_ACTUAL"))
          |> ceil()
        end,
        max: 100
      )
    end)

    UI.console("Generation & Distribution")

    loops
    |> Enum.each(fn loop ->
      UI.progress_loop(
        label: "Bypass 0#{loop}",
        fetch: fn -> API.get_float("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL") |> floor() end,
        max: 100
      )
    end)

    UI.console("Pressurizer")

    UI.progress_loop(
      label: "Core Pressure",
      fetch: fn -> API.get_float("CORE_PRESSURE") |> floor() end,
      max: 150
    )

    UI.console("Chemical Treatemnt")

    UI.progress_loop(
      label: "Boron PPM",
      fetch: fn -> API.get_float("CHEM_BORON_PPM") |> Float.round(1) end,
      max: @boron_target
    )
  end

  defp enable_resistor_bank do
    UI.console("Generation & Distribution")

    UI.set_wait(
      "Resistor Bank Main Switch",
      "ON",
      fn -> API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH") end,
      fn -> API.put("RESISTOR_BANKS_MAIN_SWITCH", true) end
    )

    UI.set_wait(
      "Resistor Bank Switch 1",
      "ON",
      fn -> API.get_boolean("RESISTOR_BANK_01_SWITCH") end,
      fn -> API.put("RESISTOR_BANK_01_SWITCH", true) end
    )
  end

  defp load_fuel do
    UI.console("Fuel")

    UI.set_wait(
      "Operating Mode",
      "NOMINAL",
      fn -> API.get_string("CORE_OPERATION_MODE") == "NOMINAL" end,
      fn -> API.put("CORE_OPERATION_MODE", "NOMINAL") end
    )

    lowered =
      1..9
      |> Enum.filter(fn core ->
        if API.get_string("CORE_BAY_#{core}_STATE") == "EXTERIOR" do
          UI.set_wait(
            "BAY #{core}: Lower Piston",
            "PRESS",
            fn -> API.get_float("CORE_FUEL_#{core}_FISSIONABLE") > 0 end,
            fn -> API.put("CORE_BAY_#{core}_FUEL_LOADING", "LOAD") end
          )

          true
        else
          false
        end
      end)

    lowered
    |> Enum.each(fn core ->
      UI.wait("BAY #{core}: Fuel Temperature Gauge", "CONFIRM ACTIVE", fn ->
        API.get_float("CORE_FUEL_#{core}_TEMPERATURE") > 20
      end)
    end)
  end

  defp achieve_criticality do
    UI.console("Reactor Core")

    bank = 0..8 |> Enum.find(fn c -> API.get_float_or_nil("ROD_BANK_POS_#{c}_ACTUAL") end)

    UI.set_wait(
      "Control Rod Height",
      "SET TO #{@startup_rods}%",
      fn -> API.get_float("ROD_BANK_POS_#{bank}_ORDERED") == @startup_rods end,
      fn -> API.put("RODS_ALL_POS_ORDERED", @startup_rods) end
    )

    UI.wait("Status", "WAIT FOR CRITICAL MASS", fn ->
      API.get_boolean("CORE_CRITICAL_MASS_REACHED")
    end)

    wait_for_temperature(100, false)
  end

  defp wait_for_temperature(temp, with_header \\ true) do
    if with_header, do: UI.console("Reactor Core")

    UI.progress_loop(
      label: "Primary Temperature",
      fetch: fn -> API.get_float("CORE_TEMP") |> round() end,
      max: temp
    )
  end

  defp start_secondary_circulation(loops) do
    UI.console("Steam Generator")

    start_pumps("SEC", "Secondary Pump", loops)
  end

  defp start_vacuum_pump do
    UI.console("Condenser")
    retention_target = AutoNuke.Operator.VacuumTank.tank_size() * @retention_percent / 100.0

    if API.get_float("VACUUM_RETENTION_TANK_VOLUME") < retention_target do
      # This is in case the script is re-run while already starting up.
      # If we don't turn off the vacuum pump, we'll likely never reach our retention target.
      UI.set_wait(
        "Vacuum Pump",
        "OFF",
        fn -> !API.get_boolean("CONDENSER_VACUUM_PUMP_ACTIVE") end,
        fn -> API.put("CONDENSER_VACUUM_PUMP_START_STOP", "STOP") end
      )
    end

    UI.progress_loop(
      label: "Retention Tank Level",
      fetch: fn ->
        API.get_float("VACUUM_RETENTION_TANK_VOLUME")
        |> floor()
      end,
      max: round(retention_target)
    )

    UI.set_wait(
      "Vacuum Pump Mode",
      "STARTUP",
      fn -> API.get_string("CONDENSER_VACUUM_PUMP_MODE") == "STARTUP" end,
      fn -> API.put("CONDENSER_VACUUM_PUMP_MODE", "STARTUP") end
    )

    UI.set_wait(
      "Vacuum Pump",
      "ON",
      fn -> API.get_boolean("CONDENSER_VACUUM_PUMP_ACTIVE") end,
      fn -> API.put("CONDENSER_VACUUM_PUMP_START_STOP", "START") end
    )

    UI.progress_loop(
      label: "Condenser Vacuum",
      fetch: fn ->
        (1 - API.get_float("CONDENSER_PRESSURE"))
        |> Kernel.*(100)
        |> round()
      end,
      max: 90
    )

    UI.set_wait(
      "Vacuum Pump Mode",
      "OPERATIONAL",
      fn -> API.get_string("CONDENSER_VACUUM_PUMP_MODE") == "OPERACIONAL" end,
      fn -> API.put("CONDENSER_VACUUM_PUMP_MODE", "OPERATIONAL") end
    )
  end

  defp start_turbine(loops) do
    UI.console("Steam Generator")
    mscv = @startup_mscv
    set_all_mscv(loops, "LIMITED (#{mscv}%)", mscv)

    UI.console("Generation & Distribution")
    set_all_bypass(loops, "CLOSED (0%)", 0)
  end

  defp connect_to_grid(loops) do
    UI.tablet("Communications Center")
    UI.set("Response", "WAIT FOR PERMISSION")

    UI.console("Generation & Distribution")

    loops
    |> Enum.each(fn loop ->
      index = loop - 1

      UI.progress_loop(
        label: "Turbine 0#{loop} RPM",
        fetch: fn -> API.get_float("STEAM_TURBINE_#{index}_RPM") |> round() end,
        max: 3050
      )

      UI.set("Turbine 0#{loop} Synchroscope", "ADJUST UNTIL SYNC")

      UI.wait("Turbine 0#{loop} Circuit Breaker", "CLOSE", fn ->
        !API.get_boolean("GENERATOR_#{index}_BREAKER")
      end)
    end)
  end

  defp begin_injecting_boron do
    UI.console("Chemical Treatment")

    init_boron = API.get_float("CHEM_BORON_PPM")

    UI.set_wait_unless(
      "Boron Injection",
      "BEGIN",
      fn -> init_boron >= @boron_target end,
      fn -> API.get_float("CHEM_BORON_PPM") > init_boron end,
      fn ->
        spawn_link(fn ->
          # Ensure only one:
          Process.register(self(), :boron_injector)
          inject_boron_loop()
        end)
      end
    )
  end

  defp inject_boron_loop do
    ppm = API.get_float("CHEM_BORON_PPM")

    rate =
      if ppm >= @boron_target do
        0
      else
        ((@boron_target - ppm) / @boron_easing)
        |> ceil()
        |> min(50)
      end

    API.put("CHEM_BORON_DOSAGE_ORDERED_RATE", rate)

    Process.sleep(500)
    inject_boron_loop()
  end

  defp get_installed_secondary_loops do
    API.get_json("INSTALLED_LOOPS_JSON")
    |> Enum.map(fn
      {"Loop_" <> loop,
       %{
         "Primary_Pump" => true,
         "Secondary_Pump" => true,
         "Steam_Generator" => true,
         "Turbine" => true
       }} ->
        String.to_integer(loop) + 1

      {_, %{}} ->
        false
    end)
    |> Enum.reject(&is_nil/1)
  end
end
