defmodule AutoNuke.Operator.CoreFill.FreightPump do
  @enforce_keys [:started]
  defstruct(@enforce_keys)

  require Logger
  alias __MODULE__, as: FP
  alias AutoNuke.API.Pumps

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @freight_pump Pumps.primary_circuit()

  def new, do: %FP{started: Pumps.get_active?(@freight_pump)}

  def start(%FP{started: true} = fp, _), do: fp

  def start(%FP{started: false}, fill) do
    Logger.info(@log_prefix <> "Fill at #{floor(fill)} m³, starting pump.")
    Pumps.set_switch(@freight_pump, true)
    %FP{started: true}
  end

  def stop(%FP{started: false} = fp, _), do: fp

  def stop(%FP{started: true}, fill) do
    Logger.info(@log_prefix <> "Fill at #{floor(fill)} m³, stopping pump.")
    Pumps.set_switch(@freight_pump, false)
    %FP{started: false}
  end
end
