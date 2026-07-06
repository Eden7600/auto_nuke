defmodule Mix.Tasks.AutoNuke.Startup do
  @moduledoc "Start the reactor from scratch"
  @shortdoc "Start the reactor"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.Operator, as: Op

  # Target PPM for boron injection:
  @boron_target 3300
  # How carefully to inject boron (higher = more):
  @boron_easing 3
  # At easing of 3, we start slowing down when boron PPM is
  # within 150 of target, since 50 g/m * 3 = 150.
  # This should allow us to miss some data ticks (which shouldn't happen anyway)
  # and still safely stop at the target.

  core_temp_min = AutoNuke.Operator.CoreTemp.temp_range().first

  # Slowly increase target temperature to this:
  @startup_core_temp core_temp_min + 5
  # Wait for this temperature before starting turbines:
  @turbine_temp core_temp_min
  # Set MSCV to this value (and let CoreTemp handle pressure):
  @startup_mscv 10

  # Start primary pumps at this speed:
  @startup_primary_speed Op.PrimaryPumps.speed_range().first
  # Start cooling pumps at this speed:
  @startup_cooling_speed 50
  # Need at least this % in the retention tank before we start the vacuum pump:
  @retention_percent 45
  # The reason we don't use 50% is that we'll already have the retention tank
  # process running and targeting 50%, and it might linger around 49%.

  # To get reactor up to temperature, increase 
  # the core temperature target by 1°C per second.
  @core_temp_increase 1 / AutoNuke.Ticker.ticks_per_second()
  # Clamp this at 5°C above the current actual temperature.
  @core_temp_max_delta 5

  def run([]) do
    startup(&get_installed_secondary_loops/0)
  end

  def run(args) do
    loops = args |> Enum.map(&UI.parse_loop/1)
    startup(fn -> loops end)
  end

  @loop_emoji "\u{1F501}"

  def startup(loops_fun) do
    UI.init()
    UI.log_to_file("startup.log")

    loops = loops_fun.()
    IO.puts("#{@loop_emoji} Starting using loops: #{inspect(loops)} #{@loop_emoji}")

    check_power_source()
    test_control_rods()

    {:ok, _} = Op.CoreFill.start_link()
    {:ok, _} = Op.PCSTFill.start_link()
    if using_boron?(), do: begin_injecting_boron()
    start_pressurizer()
    start_primary_circulation(loops, @startup_primary_speed)
    start_condenser()
    open_steam_valves(loops)
    enable_resistor_bank()

    wait_before_load_fuel(loops)
    {:ok, _} = Op.CondenserCooling.start_link()
    load_fuel()

    start_secondary_circulation(loops)

    loops
    |> Enum.each(fn loop ->
      {:ok, _} = Op.SecondaryFill.start_link(loop: loop)
    end)

    {:ok, _} = Op.CondenserFill.start_link()
    {:ok, _} = Op.CoreTemp.start_link()
    {:ok, _} = Op.PrimaryPumps.start_link()
    {:ok, _} = Op.ControlRods.start_link(mode: :direct)
    achieve_criticality()

    wait_for_min_steam()
    start_vacuum_pump()
    {:ok, _} = Op.VacuumTank.start_link()

    wait_for_temperature(@turbine_temp)
    Op.ControlRods.set_mode(:predictive)
    Op.CoreTemp.clear_override()

    request_connection()
    start_turbine(loops)
    connect_to_grid(loops)
    {:ok, _} = Op.SteamFlow.start_link()

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

  defp test_control_rods do
    UI.console("Reactor Core")

    1..9
    |> Enum.map(fn bank ->
      API.get_float_or_nil("ROD_BANK_POS_#{bank - 1}_ACTUAL")
      |> test_rod_bank(bank)
    end)
    |> Enum.any?(fn r -> r == :fail end)
    |> then(fn
      true -> Mix.raise("Check control rod motor switches.")
      false -> :ok
    end)
  end

  defp test_rod_bank(nil, bank) do
    UI.wait("Control Rod Bank 0#{bank}", "NOT INSTALLED", fn -> true end)
    :not_installed
  end

  @test_positions -5..5 |> Enum.to_list() |> List.delete(0)

  defp test_rod_bank(actual, bank) when is_float(actual) do
    key = "ROD_BANK_POS_#{bank - 1}_ORDERED"
    init_pos = API.get_float(key)
    test_pos = @test_positions |> Enum.take_random(3)

    UI.test("Control Rod Bank 0#{bank}", fn ->
      try do
        test_pos
        |> Enum.reduce_while(:pass, fn delta, :pass ->
          set_pos = (init_pos + delta / 10) |> Float.round(1)
          API.put(key, set_pos)
          Process.sleep(100)
          Memoize.invalidate(AutoNuke.API, :get_float, [key])

          case API.get_float(key) do
            ^set_pos -> {:cont, :pass}
            _ -> {:halt, :fail}
          end
        end)
      after
        API.put(key, init_pos)
      end
    end)
  end

  defp start_pressurizer do
    UI.console("Pressurizer")

    [API.Valves.pzr_vent(), API.Valves.pzr_cooling()]
    |> Enum.each(fn v ->
      if API.Valves.get_opened?(v), do: UI.Valves.close(v)
    end)

    UI.set("Thermostat", "ON")
    UI.set("Heating Power", "ON")
    UI.set("Heating Power Level", "set to HIGH")

    pzr = API.Vessels.pressurizer()

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(0, 100, "°C"),
      label: "PZR Temp",
      current_fn: fn -> API.Vessels.get_temperature(pzr) end,
      done_fn: &(&1 >= 100)
    )
  end

  def start_primary_circulation(loops, speed) do
    UI.console("Coolant System")

    pumps = loops |> Enum.map(&API.Pumps.primary/1)
    pumps |> Enum.each(&UI.Pumps.start/1)
    unless is_nil(speed), do: pumps |> Enum.each(&UI.Pumps.set_speed(&1, speed, wait: false))
  end

  defp start_condenser do
    UI.console("Condenser")

    pump = API.Pumps.condenser_cooling()
    UI.Pumps.start(pump)
    UI.Pumps.set_speed(pump, @startup_cooling_speed, wait: false)
  end

  defp open_steam_valves(loops) do
    UI.console("Steam Generator")

    loops
    |> Enum.map(&API.Valves.mscv/1)
    |> Enum.each(&UI.Valves.set(&1, 0, wait: false))

    UI.console("Generation & Distribution")

    loops
    |> Enum.map(&API.Valves.turbine_bypass/1)
    |> Enum.each(&UI.Valves.set(&1, 20, wait: false))

    UI.console("Condenser")
    API.Valves.smsi() |> UI.Valves.set(0, wait: false)
    API.Valves.omsi() |> UI.Valves.set(0, wait: false)
    API.Valves.crv() |> UI.Valves.set(0, wait: false)
  end

  defp request_connection do
    UI.tablet("Communications Center")
    UI.set("Start Operations", "REQUEST")
    IO.gets("Press enter when permission requested ...")
  end

  defp wait_before_load_fuel(loops) do
    UI.console("Pressurizer")

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(0, 150, " bar"),
      label: "Core Pressure",
      current_fn: fn -> API.get_float("CORE_PRESSURE") end,
      done_fn: &(&1 >= 150)
    )

    if using_boron?() do
      UI.console("Chemical Treatment")
      target = @boron_target - 50

      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.target(0, target, " ppm"),
        label: "Boron PPM",
        current_fn: fn -> API.get_float("CHEM_BORON_PPM") end,
        done_fn: &(&1 >= target)
      )
    end

    loops
    |> Enum.map(&API.Pumps.primary/1)
    |> Enum.each(&UI.Pumps.set_speed(&1, @startup_primary_speed, wait: true))

    UI.console("Condenser")
    API.Pumps.condenser_cooling() |> UI.Pumps.set_speed(@startup_cooling_speed, wait: true)
    API.Valves.smsi() |> UI.Valves.set(0, wait: true)
    API.Valves.omsi() |> UI.Valves.set(0, wait: true)
    API.Valves.crv() |> UI.Valves.set(0, wait: true)

    UI.console("Steam Generator")

    loops
    |> Enum.map(&API.Valves.mscv/1)
    |> Enum.each(&UI.Valves.set(&1, 0, wait: true))

    UI.console("Generation & Distribution")

    loops
    |> Enum.map(&API.Valves.turbine_bypass/1)
    |> Enum.each(&UI.Valves.set(&1, 20, wait: true))
  end

  def enable_resistor_bank do
    UI.console("Generation & Distribution")

    UI.set_wait(
      "Resistor Bank Main Switch",
      "ON",
      fn -> API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH") end,
      fn -> API.put("RESISTOR_BANKS_MAIN_SWITCH", true) end
    )

    API.get_json("RESISTOR_BANKS_JSON")
    |> Map.fetch!("resistors")
    |> Enum.each(fn {"Resistor_Bank_" <> num, bank} ->
      case Map.fetch!(bank, "IsInstalled") do
        0 ->
          UI.notice("Resistor Bank #{num} is not installed.")

        _ ->
          UI.set_wait(
            "Resistor Bank Switch #{num}",
            "ON",
            fn -> API.get_boolean("RESISTOR_BANK_#{num}_SWITCH") end,
            fn -> API.put("RESISTOR_BANK_#{num}_SWITCH", true) end
          )
      end
    end)

    capacity = API.get_float("RES_ABSORPTION_CAPACITY_MW")

    if capacity > 0 do
      UI.success("Resistor Bank Capacity: #{capacity} MW")
    else
      raise "No resistor bank capacity, cannot proceed with startup."
    end
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

    spawn_link(fn ->
      # Ensure only one:
      Process.register(self(), :temp_target)
      PubSub.subscribe(self(), :ticker)

      start_temp =
        API.Vessels.core_vessel()
        |> API.Vessels.get_temperature()
        |> ceil()

      increase_temp_target_loop(start_temp, @startup_core_temp)
    end)

    UI.wait(
      "Control Rod Height",
      "BEGIN REDUCING",
      fn -> API.get_float("RODS_POS_ACTUAL") <= 99.9 end
    )

    UI.wait("Status", "WAIT FOR CRITICAL MASS", fn ->
      API.get_boolean("CORE_CRITICAL_MASS_REACHED")
    end)

    wait_for_temperature(100, false)
  end

  defp increase_temp_target_loop(target, max) when target >= max, do: :break

  defp increase_temp_target_loop(old, max) do
    receive do
      {:tick, _} ->
        new =
          (old + @core_temp_increase)
          |> min(get_core_temp() + @core_temp_max_delta)

        Op.CoreTemp.set_override(new)
        increase_temp_target_loop(new, max)
    end
  end

  defp wait_for_temperature(temp, with_header \\ true) do
    if with_header, do: UI.console("Reactor Core")

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(0, temp, "°C"),
      label: "Core Temp",
      current_fn: &get_core_temp/0,
      done_fn: &(&1 >= temp)
    )
  end

  defp get_core_temp, do: API.get_float("CORE_TEMP")

  def start_secondary_circulation(loops) do
    UI.console("Steam Generator")

    loops
    |> Enum.each(fn loop ->
      UI.set_wait(
        "Pressure Relief Vent 0#{loop}",
        "SHUT",
        fn -> !get_vent_open?(loop) end,
        fn -> set_vent_open(loop, false) end
      )
    end)

    loops
    |> Enum.map(&API.Pumps.secondary/1)
    |> Enum.each(&UI.Pumps.start/1)
  end

  defp wait_for_min_steam do
    UI.console("Steam Generator")

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(0, 50, " kg/min", 1),
      label: "Total Steam",
      current_fn: &API.SteamGen.get_total_outlet/0,
      done_fn: &(&1 >= 50)
    )
  end

  defp start_vacuum_pump do
    UI.console("Condenser")

    API.Valves.smsi() |> UI.Valves.set(100, wait: false)

    vessel = API.Vessels.retention_tank()
    UI.Vessels.fill_wait(vessel, percent: @retention_percent)

    UI.set_wait(
      "Vacuum Pump Mode",
      "STARTUP",
      fn -> API.VacuumPump.get_mode() == :startup end,
      fn -> API.VacuumPump.set_mode(:startup) end
    )

    UI.set_wait(
      "Vacuum Pump",
      "ON",
      fn -> API.VacuumPump.get_active?() end,
      fn -> API.VacuumPump.start() end
    )

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.percent(0, 99.9),
      label: "Vacuum",
      current_fn: fn -> API.VacuumPump.get_vacuum_level() * 100 end,
      done_fn: &(&1 >= 99)
    )

    condenser = API.Vessels.condenser()

    UI.ProgressBar.wait(
      config: UI.ProgressBar.Config.target(1, 0.1, "bar", 1),
      label: "Pressure",
      current_fn: fn -> API.Vessels.get_pressure(condenser) end,
      done_fn: &(&1 <= 0.1)
    )

    UI.set_wait(
      "Vacuum Pump Mode",
      "OPERATIONAL",
      fn -> API.VacuumPump.get_mode() == :operational end,
      fn -> API.VacuumPump.set_mode(:operational) end
    )
  end

  def start_turbine(loops) do
    UI.console("Drain & Vent Valves")

    loops
    |> Enum.map(&API.Valves.turbine_vent/1)
    |> Enum.each(&UI.Valves.close/1)

    UI.console("Steam Generator")

    loops
    |> Enum.map(&API.Valves.mscv/1)
    |> Enum.each(&UI.Valves.set(&1, @startup_mscv, wait: false))

    UI.console("Generation & Distribution")

    loops
    |> Enum.map(&API.Valves.turbine_bypass/1)
    |> Enum.each(&UI.Valves.set(&1, 0, wait: false))
  end

  def connect_to_grid(loops, permission \\ true) do
    if permission do
      UI.tablet("Communications Center")
      UI.set("Response", "WAIT FOR PERMISSION")
    end

    UI.console("Generation & Distribution")

    loops
    |> Enum.each(fn loop ->
      index = loop - 1
      target = 3050

      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.target(0, target, " rpm"),
        label: "Turbine 0#{loop} RPM",
        current_fn: fn -> API.get_float("STEAM_TURBINE_#{index}_RPM") end,
        done_fn: &(&1 >= target)
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

    UI.set_wait(
      "Boron Injection",
      "BEGIN",
      fn -> API.get_float("CHEM_BORON_PPM") > min(init_boron, @boron_target) end,
      fn ->
        spawn_link(fn ->
          # Ensure only one:
          Process.register(self(), :boron_injector)
          PubSub.subscribe(self(), :ticker)
          inject_boron_loop()
        end)
      end
    )
  end

  defp inject_boron_loop do
    receive do
      {:tick, _} ->
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
        inject_boron_loop()
    end
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
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp using_boron? do
    API.Pumps.boron_dosing()
    |> API.Pumps.installed?()
  end

  defp get_vent_open?(l), do: API.SteamGen.for_loop(l) |> API.SteamGen.get_vent_open?()
  defp set_vent_open(l, v), do: API.SteamGen.for_loop(l) |> API.SteamGen.set_vent_open(v)
end
