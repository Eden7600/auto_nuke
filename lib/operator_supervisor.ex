defmodule AutoNuke.OperatorSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_) do
    [
      AutoNuke.Operator.SteamFlow,
      AutoNuke.Operator.CoreTemp,
      AutoNuke.Operator.ControlRods,
      AutoNuke.Operator.PrimaryPumps,
      {AutoNuke.Operator.SecondaryFill, loop: 1},
      {AutoNuke.Operator.SecondaryFill, loop: 2},
      {AutoNuke.Operator.SecondaryFill, loop: 3},
      AutoNuke.Operator.VacuumTank,
      AutoNuke.Operator.PCSTFill,
      AutoNuke.Operator.CoreFill,
      AutoNuke.Operator.BoronLevel,
      AutoNuke.Operator.CondenserFill,
      AutoNuke.Operator.CondenserCooling
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
