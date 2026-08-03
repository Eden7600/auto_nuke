defmodule AutoNuke.Operator.Handoff do
  @moduledoc """
  Moves the plant from task-owned operators to supervised operators.

  `mix auto_nuke.startup` historically ended in an infinite wait: its
  operators were linked to the task process, and the human Ctrl-C'd the
  whole VM and ran `./start.sh` to get supervised operators instead. When
  startup runs inside the TUI there is no second VM — this module performs
  that switch in place:

    1. stop the startup task's helper loops (boron injector, overrides),
    2. stop every unsupervised operator (state is rebuilt from the live
       plant on restart, exactly as `./start.sh` always did),
    3. start `AutoNuke.OperatorSupervisor` under the application supervisor.
  """

  require Logger

  alias AutoNuke.Operator, as: Op

  @operators [
    Op.SteamFlow,
    Op.CoreTemp,
    Op.ControlRods,
    Op.PrimaryPumps,
    Module.concat(Op.SecondaryFill, "L1"),
    Module.concat(Op.SecondaryFill, "L2"),
    Module.concat(Op.SecondaryFill, "L3"),
    Op.VacuumTank,
    Op.PCSTFill,
    Op.CoreFill,
    Op.BoronLevel,
    Op.CondenserFill,
    Op.CondenserCooling,
    Op.EmergencyPower,
    Op.ResistorBanks,
    Op.XenonGuard
  ]

  # Registered helper loops spawned by the startup task.
  @helpers [:boron_injector, :core_temp_override, :bypass_1, :bypass_2, :bypass_3]

  @doc "Are the operators already running supervised?"
  def supervised? do
    is_pid(Process.whereis(AutoNuke.OperatorSupervisor))
  end

  @doc "Is any operator running at all (supervised or not)?"
  def any_running? do
    Enum.any?(@operators, &is_pid(Process.whereis(&1)))
  end

  def adopt do
    Logger.info("[Handoff] Switching to supervised operators.")
    stop_helpers()
    stop_unsupervised_operators()
    start_supervised_operators()
  end

  defp stop_helpers do
    for name <- @helpers, pid = Process.whereis(name), is_pid(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end

  defp stop_unsupervised_operators do
    for name <- @operators, pid = Process.whereis(name), is_pid(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end
  end

  defp start_supervised_operators do
    ensure_supervisor()

    # The supervisor may be running empty (the TUI starts it with
    # `children: :none`) or with some children terminated — bring every
    # operator up either way.
    for spec <- AutoNuke.OperatorSupervisor.child_specs() do
      case Supervisor.start_child(AutoNuke.OperatorSupervisor, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> restart_operator(spec.id)
      end
    end

    :ok
  end

  defp restart_operator(id) do
    case Supervisor.restart_child(AutoNuke.OperatorSupervisor, id) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  defp ensure_supervisor do
    case Supervisor.start_child(AutoNuke.Supervisor, {AutoNuke.OperatorSupervisor, children: :none}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart_supervisor()
    end
  end

  # A previous OperatorSupervisor was stopped but its child spec remains.
  defp restart_supervisor do
    case Supervisor.restart_child(AutoNuke.Supervisor, AutoNuke.OperatorSupervisor) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end
end
