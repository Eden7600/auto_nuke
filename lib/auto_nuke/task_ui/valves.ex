defmodule AutoNuke.TaskUI.Valves do
  alias AutoNuke.API.Valves, as: ValveAPI
  alias AutoNuke.API.Valves.{ActuatedValve, OrderedValve, ManualValve}
  alias AutoNuke.TaskUI, as: UI
  alias AutoNuke.TaskUI.ProgressBar.Config, as: PBConfig

  def open(%ActuatedValve{} = v) do
    set_actuator(v, "OPEN")
    wait_until_open(v)
    set_actuator(v, "OFF")
  end

  def open(%ManualValve{} = valve) do
    UI.wait(
      valve.name,
      "OPEN",
      fn -> ValveAPI.get_opened?(valve) end
    )
  end

  def wait_until_open(%ActuatedValve{} = valve) do
    UI.ProgressBar.wait(
      config: PBConfig.percent(),
      label: valve.short_name,
      current_fn: fn -> ValveAPI.get_open_percent(valve) end
    )
  end

  def close(%ActuatedValve{} = v) do
    set_actuator(v, "CLOSE")
    wait_until_closed(v)
    set_actuator(v, "OFF")
  end

  def close(%ManualValve{} = valve) do
    UI.wait(
      valve.name,
      "CLOSE",
      fn -> !ValveAPI.get_opened?(valve) end
    )
  end

  def wait_until_closed(%ActuatedValve{} = valve) do
    UI.ProgressBar.wait(
      config: PBConfig.reverse_percent(),
      label: valve.short_name,
      current_fn: fn -> ValveAPI.get_open_percent(valve) end
    )
  end

  @actions ["OPEN", "CLOSE", "OFF"]
  def set_actuator(%ActuatedValve{} = valve, action) when action in @actions do
    UI.set_wait(
      "#{valve.name} Actuator",
      action,
      fn -> ValveAPI.get_actuator(valve) == action end,
      fn -> ValveAPI.set_actuator(valve, action) end
    )
  end

  def set(%OrderedValve{} = valve, target, opts \\ []) do
    {wait?, opts} = Keyword.pop(opts, :wait, true)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    action =
      case target do
        0 -> "CLOSED (0%)"
        100 -> "OPEN (100%)"
        n -> "LIMITED (#{n}%)"
      end

    initial = ValveAPI.get_open_percent(valve)

    UI.set_wait(
      valve.name,
      action,
      fn -> ValveAPI.get_open_percent(valve) != initial || initial == target end,
      fn -> ValveAPI.set_open_percent(valve, target) end
    )

    if wait? && initial != target do
      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.target(initial, target, "%"),
        label: valve.short_name,
        current_fn: fn -> ValveAPI.get_open_percent(valve) end
      )
    end
  end

  def bulk_open(valves) do
    valves |> Enum.each(&set_actuator(&1, "OPEN"))
    valves |> Enum.each(&open/1)
  end

  def bulk_close(valves) do
    valves |> Enum.each(&set_actuator(&1, "CLOSE"))
    valves |> Enum.each(&close/1)
  end
end
