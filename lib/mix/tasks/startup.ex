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
  @startup_rods 78
  # Stop and maintain this temperature (°C):
  @startup_temp 300
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

    check_power_source()
    start_pressurizer()
    start_primary_circulation()
    begin_injecting_boron()
    start_condenser()
    open_steam_valves()
    enable_resistor_bank()

    wait_before_load_fuel()
    load_fuel()

    start_secondary_circulation()
    {:ok, _} = AutoNuke.Operator.SecondaryFill.start_link(loop: 3)
    {:ok, _} = AutoNuke.Operator.VacuumTank.start_link()
    achieve_criticality()
    {:ok, _} = AutoNuke.Operator.CoreTemp.start_link(target: @startup_temp)
    start_vacuum_pump()
    request_connection()
    start_turbine()
    connect_to_grid()
    {:ok, _} = AutoNuke.Operator.TurbineBypass.start_link()

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

  defp start_primary_circulation do
    UI.console("Coolant System")

    # This has to come before "pump on" because we can't tell the difference
    # between a pump that is off, and a pump that is on but set to zero.
    UI.set_wait(
      "Primary Pump Speed",
      "MEDIUM (50%)",
      fn -> API.get_float("COOLANT_CORE_CIRCULATION_PUMP_2_ORDERED_SPEED") >= 50 end,
      fn -> API.put("COOLANT_CORE_CIRCULATION_PUMP_2_ORDERED_SPEED", 50) end
    )

    UI.wait("Circulation Pump 3", "ON", fn ->
      API.get_integer("COOLANT_CORE_CIRCULATION_PUMP_2_STATUS") in 1..2
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

  defp open_steam_valves do
    UI.console("Steam Generator")

    init_mscv = API.get_float("MSCV_2_OPENING_ACTUAL")

    UI.set_wait_unless(
      "Main Steam Control Valve",
      "REDUCED (#{@startup_mscv}%)",
      fn -> init_mscv == @startup_mscv end,
      fn -> API.get_float("MSCV_2_OPENING_ACTUAL") != init_mscv end,
      fn -> API.put("MSCV_2_OPENING_ORDERED", @startup_mscv) end
    )

    UI.console("Generation & Distribution")

    init_bypass = API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL")

    UI.set_wait_unless(
      "Turbine Bypass Valve 3",
      "OPEN (100%)",
      fn -> init_bypass == 100 end,
      fn -> API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL") != init_bypass end,
      fn -> API.put("STEAM_TURBINE_2_BYPASS_ORDERED", 100) end
    )

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
    UI.set("Response", "WAIT FOR PERMISSION")
    IO.gets("Press enter when permission received ...")
  end

  defp wait_before_load_fuel do
    UI.console("Coolant System")

    UI.progress_loop(
      label: "Pump Speed",
      fetch: fn ->
        API.get_float("COOLANT_CORE_CIRCULATION_PUMP_2_SPEED")
        |> floor()
      end,
      max: 50
    )

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

    UI.progress_loop(
      label: "MSCV",
      fetch: fn ->
        # Hack to support the fact that progress bars must be ascending:
        delta = abs(@startup_mscv - API.get_float("MSCV_2_OPENING_ACTUAL")) |> ceil()
        100 - delta
      end,
      max: 100
    )

    UI.console("Generation & Distribution")

    UI.progress_loop(
      label: "Bypass",
      fetch: fn -> API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL") |> floor() end,
      max: 100
    )

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

    UI.set_wait(
      "Control Rod Height",
      "SET TO #{@startup_rods}%",
      fn -> API.get_float("ROD_BANK_POS_0_ORDERED") == @startup_rods end,
      fn -> API.put("RODS_ALL_POS_ORDERED", @startup_rods) end
    )

    UI.wait("Status", "WAIT FOR CRITICAL MASS", fn ->
      API.get_boolean("CORE_CRITICAL_MASS_REACHED")
    end)

    UI.progress_loop(
      label: "Primary Temperature",
      fetch: fn -> API.get_float("CORE_TEMP") |> floor() end,
      max: @startup_temp
    )
  end

  defp start_secondary_circulation do
    UI.console("Steam Generator")

    # This has to come before "pump on" because we can't tell the difference
    # between a pump that is off, and a pump that is on but set to zero.
    UI.set_wait(
      "Secondary Pump Speed",
      "MEDIUM (50%)",
      fn -> API.get_float("COOLANT_SEC_CIRCULATION_PUMP_2_ORDERED_SPEED") >= 50 end,
      fn -> API.put("COOLANT_SEC_CIRCULATION_PUMP_2_ORDERED_SPEED", 50) end
    )

    UI.wait("Secondary Pump 3", "ON", fn ->
      API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_2_STATUS") in 1..2
    end)
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

  defp start_turbine do
    UI.console("Generation & Distribution")

    init_bypass = API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL")

    UI.set_wait_unless(
      "Turbine Bypass Valve 3",
      "CLOSED (0%)",
      fn -> init_bypass == 0 end,
      fn -> API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL") != init_bypass end,
      fn -> API.put("STEAM_TURBINE_2_BYPASS_ORDERED", 0) end
    )
  end

  defp connect_to_grid do
    UI.console("Generation & Distribution")

    UI.progress_loop(
      label: "RPM",
      fetch: fn -> API.get_float("STEAM_TURBINE_2_RPM") |> round() end,
      max: 3050
    )

    UI.set("Synchroscope / RPM", "ADJUST UNTIL SYNC")

    UI.wait("Circuit Breaker", "CLOSE", fn ->
      !API.get_boolean("GENERATOR_2_BREAKER")
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
end
