defmodule AutoNuke.OperatorSupervisor do
  use Supervisor

  @children [
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
    AutoNuke.Operator.CondenserCooling,
    AutoNuke.Operator.EmergencyPower,
    AutoNuke.Operator.ResistorBanks,
    AutoNuke.Operator.XenonGuard
  ]

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  # `children: :none` starts the supervisor empty — the TUI's mode, where
  # operators are then added individually or in bulk via start_child. The
  # default `:all` is the classic ./start.sh behaviour.
  def init(opts) when is_list(opts) do
    case Keyword.get(opts, :children, :all) do
      :all -> @children
      :none -> []
    end
    # A game-API stall makes many of the 16 operators crash at once, and
    # the default 3-restarts-in-5s gives up on the first burst. Ride out
    # a stall; still give up on a genuine crash loop.
    |> Supervisor.init(strategy: :one_for_one, max_restarts: 20, max_seconds: 10)
  end

  @doc "Resolved child specs for every operator."
  def child_specs, do: Enum.map(@children, &Supervisor.child_spec(&1, []))

  @doc "The child spec whose id is `id`, or nil."
  def spec_for(id), do: Enum.find(child_specs(), &(&1.id == id))
end
