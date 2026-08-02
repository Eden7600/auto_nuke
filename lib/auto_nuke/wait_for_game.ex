defmodule AutoNuke.WaitForGame do
  @moduledoc """
  A supervision-tree gate: blocks application startup until the game's
  webserver answers, then gets out of the way (`:ignore` — no process).

  Placed before `AutoNuke.OperatorSupervisor` when operators auto-start
  (the classic `./start.sh` path), so operators never boot against an
  unreachable game. The TUI doesn't use it — it starts operators later,
  by hand or via startup handoff.
  """

  require Logger

  @ping_wait 5000

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  def start_link do
    wait()
    :ignore
  end

  defp wait do
    case AutoNuke.API.Web.ping() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[#{inspect(__MODULE__)}] API not ready: #{reason}")
        Process.sleep(@ping_wait)
        wait()
    end
  end
end
