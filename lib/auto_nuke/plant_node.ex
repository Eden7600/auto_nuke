defmodule AutoNuke.PlantNode do
  @moduledoc """
  Finds the node where the plant operators are running.

  Three cases, checked in order:

    1. **Local** — the operators are registered in this VM (the TUI, or an
       IEx session started via `./start.sh`). Returns `Node.self()`.
    2. **Remote** — this VM was started by `./task.sh`, whose node name
       encodes the task; the operators live on `nuke@<host>`. Pings it and
       returns it.
    3. Neither — raises with instructions.

  The returned node is used in `{RegisteredName, node}` GenServer
  addresses, which work identically for the local node.
  """

  # If any of these is registered locally, the plant runs in this VM.
  @local_markers [
    AutoNuke.Operator.SteamFlow,
    AutoNuke.Operator.CoreTemp,
    AutoNuke.OperatorSupervisor
  ]

  def find(task_shell_name) do
    cond do
      local?() -> Node.self()
      true -> find_remote(task_shell_name)
    end
  end

  defp local? do
    Enum.any?(@local_markers, &is_pid(Process.whereis(&1)))
  end

  defp find_remote(task_shell_name) do
    Node.self()
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> then(fn
      ["nonode", "nohost"] ->
        Mix.raise(
          "No operators are running in this VM. " <>
            "Run this from the TUI, or via `./task.sh #{task_shell_name}`."
        )

      [_task_name, host] ->
        remote = :"nuke@#{host}"

        case Node.ping(remote) do
          :pong -> remote
          :pang -> Mix.raise("Cannot contact #{inspect(remote)}.  Is `./start.sh` running?")
        end
    end)
  end
end
