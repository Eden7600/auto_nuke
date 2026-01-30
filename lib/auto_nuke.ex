defmodule AutoNuke do
  use Application
  require Logger

  def start(_type, _args) do
    children =
      if do_start?() do
        [
          PubSub,
          AutoNuke.Ticker,
          {AutoNuke.Operator.CoreTemp, core: 1, name: :core1},
          {AutoNuke.Operator.SecondaryFill, loop: 3},
          AutoNuke.Operator.VacuumTank
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: AutoNuke.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp do_start?, do: Application.get_env(:auto_nuke, :start, false)
end
