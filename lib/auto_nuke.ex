defmodule AutoNuke do
  use Application

  def start(_type, _args) do
    case start_testing?() do
      true -> start_testing_supervisor()
      false -> start_app_supervisor()
    end
  end

  defp start_testing_supervisor do
    Supervisor.start_link(
      [AutoNuke.Test.MockAPI],
      strategy: :one_for_one,
      name: AutoNuke.Supervisor.Testing
    )
  end

  defp start_app_supervisor do
    children =
      [
        PubSub,
        AutoNuke.TimeTracker,
        AutoNuke.Ticker
      ]

    if start_operators?() do
      # The gate keeps operators from booting against an unreachable game
      # (the Ticker itself no longer blocks on connection).
      children ++ [AutoNuke.WaitForGame, AutoNuke.OperatorSupervisor]
    else
      children
    end
    |> Supervisor.start_link(
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 1,
      name: AutoNuke.Supervisor
    )
  end

  defp start_testing?, do: Application.get_env(:auto_nuke, :testing, false)

  defp start_operators? do
    case System.fetch_env("NUKE_START") do
      {:ok, "1"} -> true
      {:ok, "0"} -> false
      :error -> Application.get_env(:auto_nuke, :start, false)
    end
  end
end
