defmodule AutoNuke do
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      {AutoNuke.SecondaryFill, loop: 2},
      AutoNuke.VacuumTank
    ]

    opts = [strategy: :one_for_one, name: AutoNuke.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
