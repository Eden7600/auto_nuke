defmodule AutoNuke.Operator.CondenserFill do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:last_fill, :last_status, :freight_pump, :drain_valve, :boost_mode]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API
  alias __MODULE__.{FreightPump, DrainValve}
  alias AutoNuke.Time, as: ANTime

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @condenser API.Vessels.condenser()

  # Below 35%, run the pump to bring water up to 40%.
  @min_fill 35
  @min_fill_stop 40
  # Above 65%, open the drain valve to get water down to 60%.
  @max_fill 65
  @max_fill_stop 60
  # With boost mode enabled, fill to 60%.
  @boost_mode_limit 60

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def enable_boost_mode(expiry \\ :next_hour, pid \\ __MODULE__) do
    GenServer.call(pid, {:boost_mode, ANTime.parse_expiry(expiry)})
  end

  def disable_boost_mode(pid \\ __MODULE__) do
    GenServer.call(pid, {:boost_mode, nil})
  end

  def get_boost_mode(pid \\ __MODULE__) do
    GenServer.call(pid, :get_boost_mode)
  end

  @impl true
  def init(_) do
    fill_level = @condenser |> API.Vessels.get_fill_percent()

    state = %State{
      last_fill: fill_level,
      last_status: nil,
      freight_pump: FreightPump.new(),
      drain_valve: DrainValve.new(),
      boost_mode: nil
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with fill level #{fill_level}%.")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_boost_mode, _from, %State{boost_mode: boost} = state) do
    {:reply, boost, state}
  end

  @impl true
  def handle_call({:boost_mode, expiry}, _from, %State{} = state) do
    desc =
      case expiry do
        nil -> "disabled"
        :never -> "enabled, no expiry"
        ts -> "enabled until #{ANTime.timestamp_to_string(ts)}"
      end

    Logger.notice(@log_prefix <> "Boost mode #{desc}.")
    {:reply, :ok, %State{state | boost_mode: expiry}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state = state |> maybe_expire_boost_mode()
    fill = @condenser |> API.Vessels.get_fill_percent()
    last = state.last_status

    status =
      cond do
        state.boost_mode && fill < @boost_mode_limit -> :low
        fill > @max_fill -> :high
        fill > @max_fill_stop && last == :high -> :high
        fill < @min_fill -> :low
        fill < @min_fill_stop && last == :low -> :low
        true -> :mid
      end

    status
    |> handle_fill(fill, state)
    |> then(fn %State{} = new_state ->
      {:noreply, %State{new_state | last_fill: fill, last_status: status}}
    end)
  end

  defp handle_fill(:high, fill, state) do
    state
    |> stop_pump(fill)
    |> open_valve(fill)
  end

  defp handle_fill(:low, fill, state) do
    state
    |> close_valve(fill)
    |> start_pump(fill)
  end

  defp handle_fill(:mid, fill, state) do
    state
    |> close_valve(fill)
    |> stop_pump(fill)
  end

  defp start_pump(%State{freight_pump: fp} = state, fill),
    do: %State{state | freight_pump: fp |> FreightPump.start(fill)}

  defp stop_pump(%State{freight_pump: fp} = state, fill),
    do: %State{state | freight_pump: fp |> FreightPump.stop(fill)}

  defp open_valve(%State{drain_valve: dv, last_fill: last} = state, fill) do
    dv =
      case fill >= last do
        true -> dv |> DrainValve.open(fill)
        false -> dv |> DrainValve.hold(fill)
      end

    %State{state | drain_valve: dv}
  end

  defp close_valve(%State{drain_valve: dv} = state, fill),
    do: %State{state | drain_valve: dv |> DrainValve.close(fill)}

  defp maybe_expire_boost_mode(%State{boost_mode: nil} = state), do: state
  defp maybe_expire_boost_mode(%State{boost_mode: :never} = state), do: state

  defp maybe_expire_boost_mode(%State{boost_mode: ts} = state) when is_integer(ts) do
    if ANTime.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Boost mode has expired.")
      %State{state | boost_mode: nil}
    else
      state
    end
  end
end
