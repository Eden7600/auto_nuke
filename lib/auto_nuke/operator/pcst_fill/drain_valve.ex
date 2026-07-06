defmodule AutoNuke.Operator.PCSTFill.DrainValve do
  @enforce_keys [:open, :actuator]
  defstruct(@enforce_keys)

  require Logger
  alias __MODULE__, as: DV
  alias AutoNuke.API.Valves

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @drain_valve Valves.cst_drain()

  def new,
    do: %DV{
      open: Valves.get_opened?(@drain_valve),
      actuator: Valves.get_actuator(@drain_valve) |> actuator_to_atom()
    }

  defp actuator_to_atom("OPEN"), do: :oen
  defp actuator_to_atom("CLOSE"), do: :close
  defp actuator_to_atom("OFF"), do: :off

  def open(%DV{actuator: :open} = dv, _), do: dv

  def open(%DV{}, fill) do
    Logger.info(@log_prefix <> "Fill at #{Float.round(fill, 2)}% and rising, opening drain.")
    Valves.set_actuator(@drain_valve, "OPEN")
    %DV{open: true, actuator: :open}
  end

  def hold(%DV{actuator: :off} = dv, _), do: dv

  def hold(%DV{}, fill) do
    open = Valves.get_open_percent(@drain_valve)

    Logger.info(
      @log_prefix <>
        "Fill at #{Float.round(fill, 2)}% and dropping, holding drain at #{round(open)}%."
    )

    Valves.set_actuator(@drain_valve, "OFF")
    %DV{open: true, actuator: :off}
  end

  def close(%DV{open: false} = dv, _), do: dv

  def close(%DV{actuator: :close} = dv, _) do
    if Valves.get_opened?(@drain_valve) do
      dv
    else
      Logger.info(@log_prefix <> "Drain has finished closing.")
      Valves.set_actuator(@drain_valve, "OFF")
      %DV{open: false, actuator: :off}
    end
  end

  def close(%DV{open: true}, fill) do
    Logger.info(@log_prefix <> "Fill at #{Float.round(fill, 2)}%, closing drain.")
    Valves.set_actuator(@drain_valve, "CLOSE")
    %DV{open: true, actuator: :close}
  end

  def shutdown(%DV{open: false}), do: :noop
  def shutdown(%DV{open: true}), do: Valves.set_actuator(@drain_valve, "CLOSE")
end
