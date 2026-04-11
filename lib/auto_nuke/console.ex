defmodule AutoNuke.Console do
  alias AutoNuke.Operator.CoreFactor

  def core_status do
    [
      core_factor: CoreFactor.get_core_factor(),
      target: CoreFactor.get_target(),
      drift: CoreFactor.get_drift()
    ]
  end
end
