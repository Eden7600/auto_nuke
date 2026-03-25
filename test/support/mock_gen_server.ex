defmodule AutoNuke.Test.MockGenServer do
  use GenServer

  defmodule State do
    @enforce_keys [:module]
    defstruct(
      module: nil,
      inner_state: nil,
      timeout_at: nil
    )
  end

  def start_link(opts) do
    {module, opts} = Keyword.pop!(opts, :module)
    {before_init, opts} = Keyword.pop(opts, :before_init, fn -> :noop end)
    {init_arg, opts} = Keyword.pop(opts, :init_arg)

    GenServer.start_link(__MODULE__, {module, before_init, init_arg}, opts)
  end

  def get_timeout(pid) do
    GenServer.call(pid, {__MODULE__, :get_timeout})
  end

  def trigger_timeout(pid) do
    GenServer.cast(pid, {__MODULE__, :trigger_timeout})
  end

  def get_state(pid) do
    GenServer.call(pid, {__MODULE__, :get_state})
  end

  def execute(pid, fun) when is_function(fun) do
    GenServer.call(pid, {__MODULE__, :execute, fun})
  end

  @impl true
  def init({module, before_init, init_arg}) do
    outer = %State{module: module}
    before_init.()

    case module.init(init_arg) do
      {:ok, inner} -> encapsulate({:ok}, outer, inner)
      {:ok, inner, timeout} -> encapsulate({:ok}, outer, inner, timeout)
    end
  end

  @impl true
  def handle_cast({__MODULE__, :trigger_timeout}, outer) do
    case outer.module.handle_info(:timeout, outer.inner_state) do
      {:noreply, inner} -> encapsulate({:noreply}, outer, inner)
      {:noreply, inner, timeout} -> encapsulate({:noreply}, outer, inner, timeout)
    end
  end

  @impl true
  def handle_cast(message, outer) do
    case outer.module.handle_cast(message, outer.inner_state) do
      {:noreply, inner} -> encapsulate({:noreply}, outer, inner)
      {:noreply, inner, timeout} -> encapsulate({:noreply}, outer, inner, timeout)
    end
  end

  @impl true
  def handle_call({__MODULE__, :get_timeout}, _from, outer) do
    {:reply, outer.timeout_at, outer}
  end

  @impl true
  def handle_call({__MODULE__, :get_state}, _from, outer) do
    {:reply, outer.inner_state, outer}
  end

  @impl true
  def handle_call({__MODULE__, :execute, fun}, _from, outer) do
    {:reply, fun.(), outer}
  end

  @impl true
  def handle_call(message, from, outer) do
    case outer.module.handle_call(message, from, outer.inner_state) do
      {:reply, reply, inner} -> encapsulate({:reply, reply}, outer, inner)
      {:reply, reply, inner, timeout} -> encapsulate({:reply, reply}, outer, inner, timeout)
    end
  end

  @impl true
  def handle_info(message, outer) do
    case outer.module.handle_info(message, outer.inner_state) do
      {:noreply, inner} -> encapsulate({:noreply}, outer, inner)
      {:noreply, inner, timeout} -> encapsulate({:noreply}, outer, inner, timeout)
    end
  end

  defp encapsulate(reply, %State{} = outer, inner, timeout \\ nil) do
    timeout = msecs_to_datetime(timeout)
    outer = %State{outer | inner_state: inner, timeout_at: timeout}

    reply
    |> Tuple.to_list()
    |> Enum.concat([outer])
    |> List.to_tuple()
  end

  defp msecs_to_datetime(nil), do: nil

  defp msecs_to_datetime(ms) when is_integer(ms) do
    DateTime.utc_now()
    |> DateTime.add(ms, :millisecond)
  end
end
