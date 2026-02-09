defmodule Mix.Tasks.AutoNuke.Startup do
  @moduledoc "Start the reactor from scratch"
  @shortdoc "Start the reactor"

  use Mix.Task
  alias AutoNuke.API
  alias IO.ANSI

  def run([]) do
    Application.put_env(:auto_nuke, :start, false)
    {:ok, _} = Application.ensure_all_started([:auto_nuke])

    check_power_source()
    start_pressurizer()
    start_coolant()
    start_condenser()
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
      max: 160
    )
  end

  defp start_coolant do
    console("Coolant System")

    wait("Circulation Pump 3", "ON", fn ->
      API.get_integer("COOLANT_CORE_CIRCULATION_PUMP_2_STATUS") in 1..2
    end)

    set_wait(
      "Primary Pump Speed",
      "MEDIUM (50%)",
      fn -> API.get_float("COOLANT_CORE_CIRCULATION_PUMP_2_ORDERED_SPEED") >= 50 end,
      fn -> API.put("COOLANT_CORE_CIRCULATION_PUMP_2_ORDERED_SPEED", 50) end
    )

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

  @warning_emoji "\u26a0\ufe0f"
  @checkmark_emoji "\u2705\ufe0f"
  @right_triangle_emoji "\u25b6\ufe0f"
  @pointing_emoji "\u{1f449}\ufe0f"
  @panel_emoji "\u{1f39b}\ufe0f"
  @spin_emoji "\u{1f504}\ufe0f"
  @width 50

  defp console(name), do: IO.puts(["\n", @panel_emoji, " ", String.upcase(name), ":"])

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
      IO.puts("")
      :ok
    else
      ProgressBar.render(value, max, format)
      Process.sleep(500)
      progress_loop(fetch, max, check, format)
    end
  end
end
