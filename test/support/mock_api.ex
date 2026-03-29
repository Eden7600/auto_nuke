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

  def mock_get(key, value, opts \\ []) do
    GenServer.cast(__MODULE__, {:mock_get, self(), key, "#{value}", opts})
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
  def handle_cast({:mock_get, pid, key, value, opts}, %State{} = state) do
    {:noreply, state |> put_mock(pid, {:get, key}, value, opts)}
  end

  @impl true
  def handle_cast({:put, pid, key, value}, %State{} = state) do
    {:noreply, state |> put_mock(pid, {:put, key}, value, [])}
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
  def handle_call({:mock_put_value, pid, key}, _from, %State{} = state) do
    {rval, state} = state |> pop_mock(pid, {:put, key})
    {:reply, rval, state}
  end

  @impl true
  def handle_call({:unused_mocks, pid}, _from, %State{} = state) do
    rval =
      Map.get(state.mocks, pid, %{})
      |> Enum.flat_map(fn {{op, key}, q} ->
        q
        |> :queue.to_list()
        |> Enum.map(fn value -> {op, key, value} end)
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

  defp put_mock(%State{mocks: mocks, aliases: aliases} = state, pid, operation, value, opts) do
    pid = aliases |> Map.get(pid, pid)
    validate_opts(opts)

    new_mocks =
      mocks
      |> maybe_add_pid(pid)
      |> update_in([pid, operation], fn q ->
        q = q || :queue.new()
        :queue.in({value, opts}, q)
      end)

    %State{state | mocks: new_mocks}
  end

  defp pop_mock(%State{mocks: mocks, aliases: aliases} = state, pid, operation) do
    pid = aliases |> Map.get(pid, pid)

    get_and_update_in(mocks, [pid, operation], fn
      nil ->
        {nil, nil}

      q ->
        case :queue.out(q) do
          {{:value, {v, opts}}, new_q} ->
            remaining = Keyword.get(opts, :times, 1) - 1

            if remaining > 0 do
              new_opts = Keyword.replace(opts, :times, remaining)
              {v, :queue.in_r({v, new_opts}, new_q)}
            else
              {v, new_q}
            end

          {:empty, new_q} ->
            {nil, new_q}
        end
    end)
    |> then(fn {value, new_mocks} ->
      {value, %State{state | mocks: new_mocks}}
    end)
  end

  defp maybe_add_pid(mocks, pid) do
    case Map.has_key?(mocks, pid) do
      true ->
        mocks

      false ->
        Process.monitor(pid)
        Map.put(mocks, pid, %{})
    end
  end

  defp validate_opts([]), do: :ok
  defp validate_opts([{:times, n} | rest]) when is_integer(n), do: validate_opts(rest)
end
