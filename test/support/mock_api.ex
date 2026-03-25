defmodule AutoNuke.Test.MockAPI do
  use GenServer

  defmodule State do
    defstruct(
      mocks: %{},
      aliases: %{}
    )
  end

  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def mock_get(key, value) do
    GenServer.cast(__MODULE__, {:mock_get, self(), key, "#{value}"})
  end

  def get(key) do
    case GenServer.call(__MODULE__, {:get, self(), key}) do
      nil -> raise "API `get` call was not mocked: #{inspect(key)}"
      value -> value
    end
  end

  def put(key, value) do
    GenServer.cast(__MODULE__, {:put, self(), key, value})
  end

  def mock_put_value(key) do
    case GenServer.call(__MODULE__, {:mock_put_value, self(), key}) do
      nil -> raise "API `put` call was not received: #{inspect(key)}"
      value -> value
    end
  end

  def unused_mocks do
    GenServer.call(__MODULE__, {:unused_mocks, self()})
  end

  def register_alias(from, to) do
    GenServer.cast(__MODULE__, {:register_alias, from, to})
  end

  @impl true
  def init(_), do: {:ok, %State{}}

  @impl true
  def handle_cast({:mock_get, pid, key, value}, %State{} = state) do
    {:noreply, state |> put_mock(pid, {:get, key}, value)}
  end

  @impl true
  def handle_cast({:put, pid, key, value}, %State{} = state) do
    {:noreply, state |> put_mock(pid, {:put, key}, value)}
  end

  @impl true
  def handle_cast({:register_alias, from, to}, %State{} = state) do
    aliases =
      state.aliases
      |> Map.put_new_lazy(from, fn ->
        Process.monitor(from)
        to
      end)

    {:noreply, %State{state | aliases: aliases}}
  end

  @impl true
  def handle_call({:get, pid, key}, _from, %State{} = state) do
    {rval, state} = state |> pop_mock(pid, {:get, key})
    {:reply, rval, state}
  end

  @impl true
  def handle_call({:unused_mocks, pid}, _from, %State{} = state) do
    rval =
      Map.get(state.mocks, pid, %{})
      |> Enum.map(fn {{op, key}, value} ->
        {op, key, value}
      end)

    {:reply, rval, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{} = state) do
    {:noreply,
     %State{
       state
       | aliases: state.aliases |> Map.delete(pid),
         mocks: state.mocks |> Map.delete(pid)
     }}
  end

  defp put_mock(%State{mocks: mocks, aliases: aliases} = state, pid, operation, value) do
    pid = aliases |> Map.get(pid, pid)

    new_mocks =
      if Map.has_key?(mocks, pid) do
        put_in(mocks, [pid, operation], value)
      else
        Process.monitor(pid)
        Map.put(mocks, pid, %{operation => value})
      end

    %State{state | mocks: new_mocks}
  end

  defp pop_mock(%State{mocks: mocks, aliases: aliases} = state, pid, operation) do
    pid = aliases |> Map.get(pid, pid)

    case pop_in(mocks, [pid, operation]) do
      {nil, _} -> {nil, state}
      {value, new_mocks} -> {value, %State{state | mocks: new_mocks}}
    end
  end
end
