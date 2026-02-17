defmodule Mix.Tasks.AutoNuke.Startup do
  @moduledoc "Start the reactor from scratch"
  @shortdoc "Start the reactor"

  use Mix.Task
  alias AutoNuke.API
  alias IO.ANSI

  @width 60

  def run([]) do
    Application.put_env(:auto_nuke, :start, false)
    {:ok, _} = Application.ensure_all_started([:auto_nuke])

    {:ok, _} = PubSub.start_link()
    {:ok, _} = AutoNuke.Ticker.start_link()

    check_power_source()
    start_pressurizer()
    start_primary_circulation()
    start_condenser()
    open_steam_valves()
    request_connection()
    enable_resistor_bank()
    load_fuel()
    achieve_criticality()
    {:ok, _} = AutoNuke.Operator.CoreTemp.start_link(core: 1, target: 275)
    start_secondary_circulation()
    {:ok, _} = AutoNuke.Operator.SecondaryFill.start_link(loop: 3)
    start_vacuum_pump()
    {:ok, _} = AutoNuke.Operator.VacuumTank.start_link()
    start_turbine()
    connect_to_grid()
    {:ok, _} = AutoNuke.Operator.TurbineBypass.start_link()
    inject_boron()

    console("ALL")
    wait("Operator", "TAKE OVER", fn -> false end)
  end

  defp check_power_source do
    console("Internal Supply")

    cond do
      API.get_float("EMERGENCY_BATTERIES_POWER_OUTPUT_KW") > 0.0 ->
        warn("Currently running on batteries.")
        notice("Consider enabling external power, or starting one of the generators.")

      API.get_float("EMERGENCY_GENERATOR_POWER_OUTPUT_KW") > 0.0 ->
        warn("Currently running on emergency generators.")
        notice("Consider enabling external power, if available.")

      API.get_float("POWER_FROM_EXTERNAL_KW") > 0.0 ->
        success("Currently running on external power.")

      true ->
        warn("Can't figure out where power is coming from.")
    end
  end

  defp start_pressurizer do
    console("Pressurizer")
    set("Thermostat", "ON")
    set("Heating Power", "ON")
    set("Heating Power Level", "set to HIGH")

    progress_loop(
      label: "Core Pressure",
      fetch: fn -> API.get_float("CORE_PRESSURE") |> floor() end,
      max: 150
    )
  end

  defp start_primary_circulation do
    console("Coolant System")

    # This has to come before "pump on" because we can't tell the difference
    # between a pump that is off, and a pump that is on but set to zero.
    set_wait(
      "Primary Pump Speed",
      "MEDIUM (50%)",
      fn -> API.get_float("COOLANT_CORE_CIRCULATION_PUMP_2_ORDERED_SPEED") >= 50 end,
      fn -> API.put("COOLANT_CORE_CIRCULATION_PUMP_2_ORDERED_SPEED", 50) end
    )

    wait("Circulation Pump 3", "ON", fn ->
      API.get_integer("COOLANT_CORE_CIRCULATION_PUMP_2_STATUS") in 1..2
    end)

    progress_loop(
      label: "Pump Speed",
      fetch: fn ->
        API.get_float("COOLANT_CORE_CIRCULATION_PUMP_2_SPEED")
        |> floor()
      end,
      max: 50
    )
  end

  defp start_condenser do
    console("Condenser")

    set_wait(
      "Cooling Pump",
      "ON",
      fn -> API.get_boolean("CONDENSER_CIRCULATION_PUMP_SWITCH") end,
      fn -> API.put("CONDENSER_CIRCULATION_PUMP_SWITCH", true) end
    )

    set_wait(
      "Cooling Pump Speed",
      "MEDIUM (50%)",
      fn -> API.get_float("CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED") >= 50 end,
      fn -> API.put("CONDENSER_CIRCULATION_PUMP_ORDERED_SPEED", 50) end
    )

    progress_loop(
      label: "Pump Speed",
      fetch: fn -> API.get_float("CONDENSER_CIRCULATION_PUMP_SPEED") |> floor() end,
      max: 50
    )
  end

  defp open_steam_valves do
    console("Energy Generation")

    set_wait(
      "Turbine Bypass Valve 3",
      "OPEN (100%)",
      # No read access to BYPASS_ORDERED unfortunately.
      fn -> API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL") >= 1 end,
      fn -> API.put("STEAM_TURBINE_2_BYPASS_ORDERED", 100) end
    )

    console("Condenser")

    set_wait(
      "Startup Motive Steam Inlet",
      "OPEN (100%)",
      fn -> API.get_float("STEAM_EJECTOR_STARTUP_MOTIVE_VALVE_ORDERED") >= 100 end,
      fn -> API.put("STEAM_EJECTOR_STARTUP_MOTIVE_VALVE", 100) end
    )

    set_wait(
      "Condensate Return Valve",
      "CLOSED (0%)",
      fn -> API.get_float("STEAM_EJECTOR_CONDENSER_RETURN_VALVE_ORDERED") <= 0 end,
      fn -> API.put("STEAM_EJECTOR_CONDENSER_RETURN_VALVE", 0) end
    )

    progress_loop(
      label: "SMSI",
      fetch: fn -> API.get_float("STEAM_EJECTOR_STARTUP_MOTIVE_VALVE_ACTUAL") |> floor() end,
      max: 100
    )

    progress_loop(
      label: "CRV",
      fetch: fn ->
        (100 - API.get_float("STEAM_EJECTOR_CONDENSER_RETURN_VALVE_ACTUAL"))
        |> floor()
      end,
      max: 100
    )

    console("Energy Generation")

    progress_loop(
      label: "Bypass",
      fetch: fn -> API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL") |> floor() end,
      max: 100
    )
  end

  defp request_connection do
    tablet("Communications Center")
    set("Start Operations", "REQUEST")
    set("Response", "WAIT FOR PERMISSION")
    IO.gets("Press enter when permission received ...")
  end

  defp enable_resistor_bank do
    console("Energy Generation")

    set_wait(
      "Resistor Bank Main Switch",
      "ON",
      fn -> API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH") end,
      fn -> API.put("RESISTOR_BANKS_MAIN_SWITCH", true) end
    )

    set_wait(
      "Resistor Bank Switch 1",
      "ON",
      fn -> API.get_boolean("RESISTOR_BANK_01_SWITCH") end,
      fn -> API.put("RESISTOR_BANK_01_SWITCH", true) end
    )
  end

  defp load_fuel do
    console("Fuel")

    set_wait(
      "Operating Mode",
      "NOMINAL",
      fn -> API.get_string("CORE_OPERATION_MODE") == "NOMINAL" end,
      fn -> API.put("CORE_OPERATION_MODE", "NOMINAL") end
    )

    set_wait(
      "Lower Piston",
      "PRESS",
      fn -> API.get_float("CORE_FUEL_1_FISSIONABLE") > 0 end,
      fn -> API.put("CORE_BAY_1_FUEL_LOADING", "LOAD") end
    )

    wait("Fuel Temperature Gauge", "CONFIRM ACTIVE", fn ->
      API.get_float("CORE_FUEL_1_TEMPERATURE") > 20
    end)
  end

  defp achieve_criticality do
    console("Reactor Core")

    set_wait(
      "Control Rod Height",
      "SET TO 93%",
      fn -> API.get_float("ROD_BANK_POS_0_ORDERED") == 93.0 end,
      fn -> API.put("ROD_BANK_POS_0_ORDERED", 93.0) end
    )

    wait("Status", "WAIT FOR CRITICAL MASS", fn ->
      API.get_boolean("CORE_CRITICAL_MASS_REACHED")
    end)

    progress_loop(
      label: "Primary Temperature",
      fetch: fn -> API.get_float("CORE_TEMP") |> floor() end,
      max: 275
    )
  end

  defp start_secondary_circulation do
    console("Steam Generation")

    progress_loop(
      label: "Secondary Temperature",
      fetch: fn -> API.get_float("COOLANT_SEC_2_TEMPERATURE") |> floor() end,
      max: 100
    )

    progress_loop(
      label: "Secondary Pressure",
      fetch: fn -> API.get_float("COOLANT_SEC_2_PRESSURE") |> Float.round(1) end,
      max: 10
    )

    # This has to come before "pump on" because we can't tell the difference
    # between a pump that is off, and a pump that is on but set to zero.
    set_wait(
      "Secondary Pump Speed",
      "MEDIUM (50%)",
      fn -> API.get_float("COOLANT_SEC_CIRCULATION_PUMP_2_ORDERED_SPEED") >= 50 end,
      fn -> API.put("COOLANT_SEC_CIRCULATION_PUMP_2_ORDERED_SPEED", 50) end
    )

    wait("Secondary Pump 3", "ON", fn ->
      API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_2_STATUS") in 1..2
    end)

    progress_loop(
      label: "Pump Speed",
      fetch: fn ->
        API.get_float("COOLANT_SEC_CIRCULATION_PUMP_2_SPEED")
        |> floor()
      end,
      max: 50
    )
  end

  defp start_vacuum_pump do
    console("Condenser")

    progress_loop(
      label: "Retention Tank Level",
      fetch: fn ->
        API.get_float("VACUUM_RETENTION_TANK_VOLUME")
        |> floor()
      end,
      max: round(AutoNuke.Operator.VacuumTank.tank_size() / 2)
    )

    set_wait(
      "Vacuum Pump Mode",
      "STARTUP",
      fn -> API.get_string("CONDENSER_VACUUM_PUMP_MODE") == "STARTUP" end,
      fn -> API.put("CONDENSER_VACUUM_PUMP_MODE", "STARTUP") end
    )

    set_wait(
      "Vacuum Pump",
      "ON",
      fn -> API.get_boolean("CONDENSER_VACUUM_PUMP_ACTIVE") end,
      fn -> API.put("CONDENSER_VACUUM_PUMP_START_STOP", "START") end
    )
    # We sometimes stall here and I can't figure out why.
    |> IO.inspect(label: "vacuum pump set_wait")

    progress_loop(
      label: "Condenser Pressure",
      fetch: fn ->
        API.get_float("CONDENSER_PRESSURE")
        |> IO.inspect(label: "condenser pressure")
        |> Kernel.*(-1)
        |> Float.round(2)
      end,
      max: -0.1
    )

    set_wait(
      "Vacuum Pump Mode",
      "OPERATIONAL",
      fn -> API.get_string("CONDENSER_VACUUM_PUMP_MODE") == "OPERACIONAL" end,
      fn -> API.put("CONDENSER_VACUUM_PUMP_MODE", "OPERATIONAL") end
    )
  end

  defp start_turbine do
    console("Energy Generation")

    set_wait(
      "Turbine Bypass Valve 3",
      "CLOSED (0%)",
      # No read access to BYPASS_ORDERED unfortunately.
      fn -> API.get_float("STEAM_TURBINE_2_BYPASS_ACTUAL") <= 99 end,
      fn -> API.put("STEAM_TURBINE_2_BYPASS_ORDERED", 0) end
    )
  end

  defp connect_to_grid do
    console("Energy Generation")

    progress_loop(
      label: "RPM",
      fetch: fn -> API.get_float("STEAM_TURBINE_2_RPM") |> round() end,
      max: 3050
    )

    set("Synchroscope / RPM", "ADJUST UNTIL SYNC")

    wait("Circuit Breaker", "CLOSE", fn ->
      !API.get_boolean("GENERATOR_2_BREAKER")
    end)
  end

  defp inject_boron do
    console("Chemical Treatment")

    progress_loop(
      label: "Boron PPM",
      fetch: fn ->
        ppm = API.get_float("CHEM_BORON_PPM")

        rate =
          if ppm >= 3000 do
            0
          else
            ((3000 - ppm) / 10)
            |> ceil()
            |> min(50)
          end

        API.put("CHEM_BORON_DOSAGE_ORDERED_RATE", rate)

        ppm
        |> floor()
      end,
      max: 3000
    )

    console("Reactor Core")

    progress_loop(
      label: "Primary Temperature",
      fetch: fn -> API.get_float("CORE_TEMP") |> floor() end,
      max: 275
    )
  end

  @warning_emoji "\u26a0\ufe0f"
  @checkmark_emoji "\u2705\ufe0f"
  @right_triangle_emoji "\u25b6\ufe0f"
  @pointing_emoji "\u{1f449}\ufe0f"
  @panel_emoji "\u{1f39b}\ufe0f"
  @spin_emoji "\u{1f504}\ufe0f"
  # @hourglass_emoji "\u23f3\ufe0f"
  @phone_emoji "\u{1f4f2}\ufe0f"

  defp console(name), do: IO.puts(["\n", @panel_emoji, " ", String.upcase(name), ":"])
  defp tablet(name), do: IO.puts(["\n", @phone_emoji, " ", String.upcase(name), ":"])

  defp set(key, value) do
    dot_line(key, value, @pointing_emoji) |> IO.puts()
  end

  defp wait(key, value, check) do
    line = dot_line(key, value)
    wait_loop(line, check)
  end

  defp set_wait(key, value, check, set) do
    line = dot_line(key, value)
    wait_loop(line, check, set)
  end

  defp wait_loop(line, check, set \\ fn -> :noop end) do
    if check.() do
      IO.puts(["\r", @checkmark_emoji, "  ", line])
    else
      IO.write(["\r", @pointing_emoji, "  ", line])
      set.()
      Process.sleep(500)
      wait_loop(line, check)
    end
  end

  defp dot_line(key, value, emoji \\ nil) do
    dot_count = @width - String.length(key) - String.length(value) - 6
    dots = String.duplicate(".", max(dot_count, 3))
    line = [key, " ", dots, " ", value]

    case emoji do
      nil -> line
      str when is_binary(str) -> [emoji, "  " | line]
    end
  end

  defp warn(msg) do
    IO.puts([
      ANSI.yellow(),
      @warning_emoji,
      " ",
      msg,
      ANSI.reset()
    ])
  end

  defp success(msg), do: IO.puts([@checkmark_emoji, "  ", msg])
  defp notice(msg), do: IO.puts([@right_triangle_emoji, "  ", msg])

  defp progress_loop(opts) do
    fetch = Keyword.fetch!(opts, :fetch)
    max = Keyword.fetch!(opts, :max)
    check = Keyword.get(opts, :check, fn v -> v >= max end)

    label =
      case Keyword.fetch(opts, :label) do
        {:ok, l} -> "#{@spin_emoji}  #{l}"
        :error -> "#{@spin_emoji} "
      end

    format = [
      left: "#{label} [",
      right: "]",
      width: @width - 1,
      percent: false,
      suffix: :count
    ]

    progress_loop(fetch, max, check, format)
  end

  defp progress_loop(fetch, max, check, format) do
    value = fetch.()

    if check.(value) do
      format = Keyword.update!(format, :left, &String.replace(&1, @spin_emoji, @checkmark_emoji))
      ProgressBar.render(min(value, max), max, format)
      :ok
    else
      ProgressBar.render(value, max, format)
      Process.sleep(500)
      progress_loop(fetch, max, check, format)
    end
  end
end
