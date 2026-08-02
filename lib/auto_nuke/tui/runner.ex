defmodule AutoNuke.Tui.Runner do
  @moduledoc """
  Runs one plant task (a zero-arity function wrapping an existing Mix task
  flow) in a monitored background process, with its console output captured
  by `AutoNuke.Tui.IOCapture`.

  The owner process receives:

    * `{:task_output, lines}` — refreshed output pane content
    * `{:DOWN, ref, :process, pid, reason}` — completion; classify it with
      `result/2`

  Only one task runs at a time by design: plant procedures are exclusive.
  """

  defstruct [:name, :pid, :ref, :capture]

  alias __MODULE__, as: Runner
  alias AutoNuke.Tui.IOCapture

  @doc "Start `fun` as a captured background task owned by the caller."
  def start(name, fun) when is_function(fun, 0) do
    owner = self()
    {:ok, capture} = IOCapture.start(owner)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), capture)
        fun.()
      end)

    %Runner{name: name, pid: pid, ref: ref, capture: capture}
  end

  @doc """
  Abort the running task.

  Note: anything linked to the task process dies with it — cancelling a
  startup mid-run also stops the operators it has started so far.
  """
  def cancel(%Runner{pid: pid}), do: Process.exit(pid, :kill)

  @doc "Release the output capture once the pane is closed."
  def release(%Runner{capture: capture}), do: IOCapture.stop(capture)

  @doc "Does this DOWN message belong to this runner?"
  def down?(%Runner{ref: ref}, {:DOWN, ref, :process, _pid, _reason}), do: true
  def down?(%Runner{}, _message), do: false

  @doc "Classify a DOWN reason into a display result."
  def result(:normal), do: :ok
  def result(:killed), do: {:error, "Cancelled."}
  def result({%Mix.Error{message: message}, _stack}), do: {:error, message}
  def result({%{__exception__: true} = e, _stack}), do: {:error, Exception.message(e)}
  def result(reason), do: {:error, inspect(reason)}
end
