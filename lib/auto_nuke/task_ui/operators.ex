defmodule AutoNuke.TaskUI.Operators do
  alias AutoNuke.Operator.ResistorBanks
  alias AutoNuke.TaskUI, as: UI

  def resistor_banks_hold(server) do
    case ResistorBanks.hold(server) do
      :ok -> UI.set("Resistor Banks Operator", "HOLD")
      {:error, :not_running} -> UI.notice("Resistor Banks Operator is not running.")
    end
  end

  def resistor_banks_release(server) do
    case ResistorBanks.release(server) do
      :ok -> UI.set("Resistor Banks Operator", "RESUME")
      {:error, :not_running} -> UI.notice("Resistor Banks Operator is not running.")
    end
  end
end
