defmodule AutoNuke.LoopIntent do
  @moduledoc """
  The plant-wide understanding of which loops are *meant* to be in
  service.

  Tasks and operators that bring loops in or out of service record their
  intent here, and every loop-aware operator reconciles its own loop list
  against it each tick. Without this, a task that informs one operator
  but not another leaves the plant half-informed — the failure mode where
  stopping a loop left CoreTemp holding core temperature against the
  stopped loop's vented steam generator, driving the target to 400°C.

  Intent is only tracked for loops something has explicitly claimed;
  operators leave unknown loops alone. All calls tolerate the registry
  not running at all (legacy task VMs): writes report `:not_running` and
  reads fall back to "no opinion".
  """

  use GenServer

  @loops 1..3

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def set_active(loop, server \\ __MODULE__) when loop in @loops,
    do: set_intent(server, loop, :active)

  def set_stopped(loop, server \\ __MODULE__) when loop in @loops,
    do: set_intent(server, loop, :stopped)

  @doc "Known intents, as a map of loop => :active | :stopped."
  def intents(server \\ __MODULE__) do
    GenServer.call(server, :intents)
  catch
    :exit, _ -> %{}
  end

  defp set_intent(server, loop, intent) do
    GenServer.call(server, {:set_intent, loop, intent})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({:set_intent, loop, intent}, _from, intents),
    do: {:reply, :ok, Map.put(intents, loop, intent)}

  @impl true
  def handle_call(:intents, _from, intents), do: {:reply, intents, intents}
end
