defmodule AutoNuke do
  use Application

  def start(_type, _args) do
    children =
      if Application.get_env(:auto_nuke, :testing, false) do
        testing_children()
      else
        base_children() ++ automation_children()
      end

    opts = [
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 1,
      name: AutoNuke.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  defp base_children do
    [
      PubSub,
      AutoNuke.TimeTracker,
      AutoNuke.Ticker
    ]
  end

  defp automation_children do
    if do_start?() do
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
    else
      []
    end
  end

  defp testing_children do
    [
      AutoNuke.Test.MockAPI
    ]
  end

  defp do_start? do
    case System.fetch_env("NUKE_START") do
      {:ok, "1"} -> true
      {:ok, "0"} -> false
      :error -> Application.get_env(:auto_nuke, :start, false)
    end
  end
end
