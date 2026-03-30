defmodule AutoNuke do
  use Application
  require Logger

  def start(_type, _args) do
    children = app_children() ++ testing_children()

    opts = [strategy: :one_for_one, name: AutoNuke.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp app_children do
    if do_start?() do
      [
        PubSub,
        AutoNuke.Ticker,
        AutoNuke.Operator.CoreFactor,
        AutoNuke.Operator.CoreTemp,
        AutoNuke.Operator.SteamFlow,
        {AutoNuke.Operator.SecondaryFill, loop: 1},
        {AutoNuke.Operator.SecondaryFill, loop: 2},
        {AutoNuke.Operator.SecondaryFill, loop: 3},
        AutoNuke.Operator.VacuumTank,
        AutoNuke.Operator.CondenserCooling
      ]
    else
      []
    end
  end

  defp testing_children do
    if Application.get_env(:auto_nuke, :testing, false) do
      [
        AutoNuke.Test.MockAPI
      ]
    else
      []
    end
  end

  defp do_start? do
    case System.fetch_env("NUKE_START") do
      {:ok, "1"} -> true
      {:ok, "0"} -> false
      :error -> Application.get_env(:auto_nuke, :start, false)
    end
  end
end
