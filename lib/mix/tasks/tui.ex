defmodule Mix.Tasks.AutoNuke.Tui do
  @moduledoc """
  Launch the interactive AutoNuke TUI.

      mix auto_nuke.tui           # the real thing (dashboard + tasks)
      mix auto_nuke.tui --demo    # engine demo (no game connection needed)
  """
  @shortdoc "Launch the interactive TUI"

  use Mix.Task

  def run(["--demo"]) do
    # The demo needs no API connection and no operators.
    Application.put_env(:auto_nuke, :start, false)

    AutoNuke.Tui.run(AutoNuke.Tui.Demo)
    |> handle_result()
  end

  def run([]) do
    # In the TUI every operator starts OFF — enable them from the [o] menu
    # (or let the Startup task hand off to them). This overrides
    # NUKE_START / config, which only apply to ./start.sh.
    Application.put_env(:auto_nuke, :start, false)
    System.put_env("NUKE_START", "0")

    IO.puts("Connecting to the Nucleares webserver...")
    {:ok, _} = Application.ensure_all_started([:auto_nuke, :logger])

    # Supervisor up, zero operators running: [o] can then enable each one.
    {:ok, _} =
      Supervisor.start_child(AutoNuke.Supervisor, {AutoNuke.OperatorSupervisor, children: :none})

    # Console logging would draw over the TUI; send it to a file instead,
    # plus an in-memory ring buffer for the TUI's log pane.
    AutoNuke.TaskUI.log_to_file("tui.log")
    AutoNuke.Tui.LogBuffer.attach()

    AutoNuke.Tui.run(AutoNuke.Tui.Dashboard)
    |> handle_result()
  end

  defp handle_result(:ok), do: :ok

  defp handle_result({:error, reason}) do
    Mix.raise("""
    Could not start the TUI: #{inspect(reason)}

    The TUI needs an interactive terminal (it reads single keystrokes).
    Run it directly from Windows Terminal / your shell, not through a pipe.
    """)
  end
end
