defmodule Mix.Tasks.AutoNuke.Startup do
  @moduledoc "Start the reactor from scratch"
  @shortdoc "Start the reactor"

  use Mix.Task
  require Logger
  alias AutoNuke.API
  alias AutoNuke.Smoother
  alias AutoNuke.ControlAxis
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

  # Slowly increase target temperature to this:
  @core_temp_min 320
  # Wait for this temperature before starting turbines:
  @turbine_temp 300
  # Prior to turbine startup, set bypass to achieve 60 bar:
  @bypass_target_pressure 60
  # To start turbines, set MSCV to this value while we close the bypass.
  # Once that's done, SteamFlow will take over MSCV and bypass control.
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
  # Clamp this at 10°C above the current actual temperature.
  @core_temp_max_delta 10

  def run([]) do
    startup(
      &get_installed_secondary_loops/0,
      &get_loaded_core_bays/0
    )
  end

  def run([loops]) do
    startup(
      parse_loops(loops),
      &get_loaded_core_bays/0
    )
  end

  def run([loops, cores]) do
    startup(
      parse_loops(loops),
      parse_cores(cores)
    )
  end

  @loop_emoji "\u{1F501}"
  @core_emoji "\u{2622}\u{FE0F}"

  def startup(loops_fun, cores_fun) do
    UI.init()
    UI.log_to_file("startup.log")

    loops = loops_fun.()
    cores = cores_fun.()
    IO.puts("#{@loop_emoji} Starting using loops: #{inspect(loops)} #{@loop_emoji}")
    IO.puts("#{@core_emoji} Starting using cores: #{inspect(cores)} #{@core_emoji}")

    check_power_source()
    test_control_rods()

    {:ok, _} = Op.CoreFill.start_link()
    {:ok, _} = Op.PCSTFill.start_link()
    if using_boron?(), do: begin_injecting_boron()
    start_pressurizer()
    start_primary_circulation(loops, @startup_primary_speed)
    start_condenser()
    open_steam_valves(loops)
    capacity = enable_resistor_bank()

    wait_before_load_fuel(loops)
    {:ok, _} = Op.CondenserCooling.start_link()
    load_fuel(cores)

    start_secondary_circulation(loops)

    loops
    |> Enum.each(fn loop ->
      {:ok, _} = Op.SecondaryFill.start_link(loop: loop)
    end)

    {:ok, _} = Op.CondenserFill.start_link()

    start_reaction()
    {:ok, _} = Op.CoreTemp.start_link(loops: loops)
    {:ok, _} = Op.PrimaryPumps.start_link()
    {:ok, _} = Op.ControlRods.start_link(mode: :direct)
    achieve_criticality()

    wait_for_min_steam()
    start_vacuum_pump()
    {:ok, _} = Op.VacuumTank.start_link()

    reduce_bypass(loops)
    wait_for_temperature(@turbine_temp)

    request_connection()
    start_turbine(loops)

    {:ok, _} = Op.SteamFlow.start_link(loops: loops, override: {capacity / 3, :mw})
    send(:core_temp_override, :exit)

    connect_to_grid(loops)
    Op.SteamFlow.set_target_override_percent(100)

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
    |> UI.Valves.bulk_close()

    UI.set("Thermostat", "ON")
    UI.set("Heating Power Level", "set to HIGH")

    UI.wait(
      "Heating Power",
      "ON",
      fn -> API.get_boolean("PRESSURIZER_HEATERS_ON") end
    )

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
    |> Enum.each(&UI.Valves.set(&1, 100, wait: false))

    UI.console("Condenser")
    API.Valves.smsi() |> UI.Valves.set(0, wait: false)
    API.Valves.omsi() |> UI.Valves.set(0, wait: false)
    API.Valves.crv() |> UI.Valves.set(0, wait: false)
  end

  defp request_connection do
    UI.tablet("Communications Center")
    UI.set("Start Operations", "REQUEST")
    UI.set("Response", "WAIT FOR PERMISSION")
    IO.gets("Press enter when ready to start ...")
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
    |> Enum.each(&UI.Valves.set(&1, 100, wait: true))
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
      capacity
    else
      raise "No resistor bank capacity, cannot proceed with startup."
    end
  end

  defp load_fuel(cores) do
    UI.console("Fuel")

    UI.set_wait(
      "Operating Mode",
      "NOMINAL",
      fn -> API.get_string("CORE_OPERATION_MODE") == "NOMINAL" end,
      fn -> API.put("CORE_OPERATION_MODE", "NOMINAL") end
    )

    cores
    |> Enum.each(fn core ->
      if API.get_string("CORE_BAY_#{core}_STATE") == "EXTERIOR" do
        UI.set_wait(
          "BAY #{core}: Lower Piston",
          "PRESS",
          fn -> API.get_float("CORE_FUEL_#{core}_FISSIONABLE") > 0 end,
          fn -> API.put("CORE_BAY_#{core}_FUEL_LOADING", "LOAD") end
        )
      end
    end)

    cores
    |> Enum.each(fn core ->
      UI.wait("BAY #{core}: Fuel Temperature Gauge", "CONFIRM ACTIVE", fn ->
        API.get_float("CORE_FUEL_#{core}_TEMPERATURE") > 20
      end)
    end)
  end

  defp start_reaction do
    UI.console("Reactor Core")

    UI.set_wait(
      "Control Rod Height",
      "BEGIN REDUCING",
      fn -> API.get_float("RODS_POS_ACTUAL") <= 99.9 end,
      fn -> API.put("RODS_ALL_POS_ORDERED", 0.0) end
    )

    UI.wait(
      "Core Factor",
      "WAIT FOR REACTION",
      fn -> API.get_float("CORE_FACTOR") > 0.0 end
    )

    # Freeze rods where they are:
    API.put("RODS_ALL_POS_ORDERED", API.get_float("RODS_POS_ACTUAL"))
  end

  defp achieve_criticality do
    spawn_link(fn ->
      # Ensure only one:
      Process.register(self(), :core_temp_override)
      PubSub.subscribe(self(), :ticker)

      start_temp =
        API.Vessels.core_vessel()
        |> API.Vessels.get_temperature()
        |> ceil()

      increase_temp_target_loop(start_temp)
    end)

    UI.wait("Status", "WAIT FOR CRITICAL MASS", fn ->
      API.get_boolean("CORE_CRITICAL_MASS_REACHED")
    end)

    wait_for_temperature(100, false)
  end

  defp increase_temp_target_loop(old) do
    receive do
      {:tick, _} ->
        temp = get_core_temp()

        if temp > @core_temp_min - 5 do
          Op.CoreTemp.set_override(@core_temp_min, :never)
          Op.ControlRods.set_mode(:predictive)
          PubSub.unsubscribe(self(), :ticker)
          increase_temp_target_loop(@core_temp_min)
        else
          new =
            (old + @core_temp_increase)
            |> min(temp + @core_temp_max_delta)

          Op.CoreTemp.set_override(new, :never)
          increase_temp_target_loop(new)
        end

      :exit ->
        Op.CoreTemp.clear_override()
        Op.ControlRods.set_mode(:predictive)
    end
  end

  defp reduce_bypass(loops) do
    UI.console("Generation & Distribution")

    loops
    |> Enum.each(fn loop ->
      steam_gen = API.SteamGen.for_loop(loop)
      name = bypass_task_name(loop)

      UI.set_wait(
        steam_gen.bypass.name,
        "SET FOR #{@bypass_target_pressure} bar",
        fn -> Process.whereis(name) |> is_pid() end,
        fn -> bypass_for_pressure(name, steam_gen) end
      )
    end)
  end

  defp bypass_task_name(loop), do: :"bypass_#{loop}"

  defp bypass_for_pressure(name, steam_gen) do
    me = self()

    spawn_link(fn ->
      Process.register(self(), name)
      PubSub.subscribe(self(), :ticker)
      send(me, {:started, name})

      smoother = Smoother.new(10)

      ControlAxis.new(
        kp: -0.01,
        ki: -0.0005,
        kd: -0.001,
        deadzone: 0.5,
        to_value_fn: &axis_to_bypass/1,
        offset: 1.0,
        initial_value: API.Valves.get_open_percent(steam_gen.mscv) |> round()
      )
      |> bypass_pressure_loop(smoother, steam_gen)
    end)

    receive do
      {:started, ^name} -> :ok
    after
      5000 -> raise "No word from bypass_for_pressure process"
    end
  end

  defp bypass_pressure_loop(axis, smoother, steam_gen) do
    receive do
      {:tick, _} ->
        smoother = Smoother.add(smoother, API.SteamGen.get_pressure(steam_gen))

        case ControlAxis.step(
               axis,
               @bypass_target_pressure,
               Smoother.extrapolate(smoother, 5)
             ) do
          {:changed, axis, new, old} ->
            Logger.debug("Changing bypass from #{old} to #{new}.")
            API.Valves.set_open_percent(steam_gen.bypass, new)
            axis

          {:unchanged, axis, _old} ->
            axis
        end
        |> bypass_pressure_loop(smoother, steam_gen)

      :exit ->
        :done
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
    |> UI.Valves.bulk_close()

    UI.console("Steam Generator")

    loops
    |> Enum.map(&API.Valves.mscv/1)
    |> Enum.each(&UI.Valves.set(&1, @startup_mscv, wait: false))

    UI.console("Generation & Distribution")

    loops
    |> Enum.each(fn loop ->
      bypass_task_name(loop)
      |> send(:exit)
    end)

    loops
    |> Enum.map(&API.Valves.turbine_bypass/1)
    |> Enum.each(&API.Valves.set_open_percent(&1, 0))

    loops
    |> Enum.map(&API.Valves.turbine_bypass/1)
    |> Enum.each(&UI.Valves.set(&1, 0, wait: true))
  end

  def connect_to_grid(loops) do
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

  defp get_loaded_core_bays do
    1..9
    |> Enum.filter(fn core ->
      case API.get_string("CORE_BAY_#{core}_STATE") do
        "EXTERIOR" -> true
        "INTERIOR" -> true
        "VACIO" -> false
      end
    end)
  end

  defp using_boron? do
    API.Pumps.boron_dosing()
    |> API.Pumps.installed?()
  end

  defp get_vent_open?(l), do: API.SteamGen.for_loop(l) |> API.SteamGen.get_vent_open?()
  defp set_vent_open(l, v), do: API.SteamGen.for_loop(l) |> API.SteamGen.set_vent_open(v)

  defp axis_to_bypass(output), do: round(output * 50) + 50

  defp parse_loops(l), do: parse_arg(l, "[1-3A-Ca-c]", &UI.parse_loop/1) |> wrap_arg()
  defp parse_cores(c), do: parse_arg(c, "[1-9]", &String.to_integer/1) |> wrap_arg()

  defp parse_arg(arg, rx, fun) do
    cond do
      arg == "all" ->
        1..3

      arg =~ ~r/^#{rx}$/ ->
        [fun.(arg)]

      match = Regex.run(~r/^(#{rx})\.\.(#{rx})$/, arg) ->
        [_, first, last] = match
        fun.(first)..fun.(last)

      String.contains?(arg, ",") ->
        arg
        |> String.split(",")
        |> Enum.flat_map(&parse_arg(&1, rx, fun))
    end
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp wrap_arg(value), do: fn -> value end
end
