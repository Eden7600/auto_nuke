defmodule AutoNuke.Operator do
  alias __MODULE__, as: Op

  def assigned_tick(Op.CoreFactor), do: 0
  def assigned_tick(Op.SteamFlow), do: 0
  def assigned_tick(Op.CorePower), do: 1
  def assigned_tick(Op.CoreTemp), do: 2
  def assigned_tick(Op.SecondaryFill), do: 3
  def assigned_tick(Op.VacuumTank), do: 3
  def assigned_tick(Op.CondenserFill), do: 4
  def assigned_tick(Op.CondenserCooling), do: 4

  def assigned_tick_modulo(Op.CorePower), do: 40
  def assigned_tick_modulo(_), do: 5

  defmacro __using__(_) do
    quote do
      @my_tick AutoNuke.Operator.assigned_tick(__MODULE__)
      @my_tick_modulo AutoNuke.Operator.assigned_tick_modulo(__MODULE__)
      defguard is_my_tick(t) when rem(t, @my_tick_modulo) == @my_tick
    end
  end
end
