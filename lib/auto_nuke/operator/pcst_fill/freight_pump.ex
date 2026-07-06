defmodule AutoNuke.Operator.PCSTFill.FreightPump do
  @enforce_keys [:started]
  defstruct(@enforce_keys)

  require Logger
  alias __MODULE__, as: FP
  alias AutoNuke.API.{Pumps, Valves}

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @freight_pump Pumps.internal_freight()
  @valve Valves.valve_m03()

  def new, do: %FP{started: Pumps.get_active?(@freight_pump)}

  def start(%FP{started: true} = fp, _) do
    if Valves.get_opened?(@valve) do
      fp
    else
      Logger.error(@log_prefix <> @valve.name <> " is closed, stopping pump!")
      Pumps.set_switch(@freight_pump, false)
      %FP{started: false}
    end
  end

  def start(%FP{started: false} = fp, fill) do
    if Valves.get_opened?(@valve) do
      Logger.info(@log_prefix <> "Fill at #{Float.round(fill, 2)}%, starting pump.")
      Pumps.set_switch(@freight_pump, true)
      %FP{started: true}
    else
      Logger.error(@log_prefix <> @valve.name <> " is closed, cannot fill PCST!")
      fp
    end
  end

  def stop(%FP{started: false} = fp, _), do: fp

  def stop(%FP{started: true}, fill) do
    Logger.info(@log_prefix <> "Fill at #{Float.round(fill, 2)}%, stopping pump.")
    Pumps.set_switch(@freight_pump, false)
    %FP{started: false}
  end

  def shutdown(%FP{started: false}), do: :noop
  def shutdown(%FP{started: true}), do: Pumps.set_switch(@freight_pump, false)
end
