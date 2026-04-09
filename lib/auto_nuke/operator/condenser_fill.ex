defmodule AutoNuke.Operator.CondenserFill do
  use GenServer
  require Logger

  # Run on the fourth tick each second:
  @ticks_per_second AutoNuke.Ticker.ticks_per_second()
  defguard is_my_tick(t) when rem(t, @ticks_per_second) == 3

  defmodule State do
    @enforce_keys [:last_fill, :freight_pump, :drain_valve]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.API
  alias __MODULE__.{FreightPump, DrainValve}

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")
  @condenser API.Vessels.condenser()

  # Below 40%, run the pump to bring in more water.
  @min_fill 40
  # Above 60%, open the drain valve.
  @max_fill 60

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    fill_level = @condenser |> API.Vessels.get_fill_percent()

    state = %State{
      last_fill: fill_level,
      freight_pump: FreightPump.new(),
      drain_valve: DrainValve.new()
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with fill level #{fill_level}%.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    fill = @condenser |> API.Vessels.get_fill_percent()

    cond do
      fill > @max_fill -> :high
      fill < @min_fill -> :low
      true -> :mid
    end
    |> handle_fill(fill, state)
    |> then(fn %State{} = new_state ->
      {:noreply, %State{new_state | last_fill: fill}}
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
end
