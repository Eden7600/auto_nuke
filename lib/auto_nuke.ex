defmodule AutoNuke do
  use Application
  require Logger

  def start(_type, _args) do
    children =
      if do_start?() do
        [
          PubSub,
          AutoNuke.Ticker,
          AutoNuke.Operator.CoreTemp,
          {AutoNuke.Operator.SecondaryFill, loop: 3},
          AutoNuke.Operator.VacuumTank,
          AutoNuke.Operator.TurbineBypass
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: AutoNuke.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp do_start? do
    case System.fetch_env("NUKE_START") do
      {:ok, "1"} -> true
      {:ok, "0"} -> false
      :error -> Application.get_env(:auto_nuke, :start, false)
    end
  end
end
