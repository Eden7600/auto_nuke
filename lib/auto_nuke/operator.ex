defmodule AutoNuke.Operator do
  alias __MODULE__, as: Op

  # Core concerns:
  def assigned_tick(Op.SteamFlow), do: 0
  def assigned_tick(Op.CoreTemp), do: 1
  def assigned_tick(Op.ControlRods), do: 2
  def assigned_tick(Op.PrimaryPumps), do: 3
  def assigned_tick(Op.BoronLevel), do: 4

  # Auxiliary concerns:
  def assigned_tick(Op.CoreFill), do: 0
  def assigned_tick(Op.PCSTFill), do: 0
  def assigned_tick(Op.SecondaryFill), do: 1
  def assigned_tick(Op.VacuumTank), do: 2
  def assigned_tick(Op.CondenserFill), do: 3
  def assigned_tick(Op.CondenserCooling), do: 4
  def assigned_tick(Op.EmergencyPower), do: 1
  def assigned_tick(Op.ResistorBanks), do: 3

  def assigned_tick_modulo(Op.PCSTFill), do: 25
  def assigned_tick_modulo(_), do: 5

  @doc """
  Unsubscribe a named operator from a topic, but only if it's actually
  running.

  `PubSub.unsubscribe/2` resolves the name and then unlinks it — handing
  it the name of a process that doesn't exist crashes the PubSub server
  itself, taking the rest of the supervision tree with it.
  """
  def unsubscribe_if_running(name, topic) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> PubSub.unsubscribe(pid, topic)
    end
  end

  defmacro __using__(_) do
    quote do
      @my_tick AutoNuke.Operator.assigned_tick(__MODULE__)
      @my_tick_modulo AutoNuke.Operator.assigned_tick_modulo(__MODULE__)
      defguard is_my_tick(t) when rem(t, @my_tick_modulo) == @my_tick
    end
  end
end
