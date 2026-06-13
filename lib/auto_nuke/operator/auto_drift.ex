defmodule AutoNuke.Operator.AutoDrift do
  use GenServer
  use AutoNuke.Operator
  require Logger

  defmodule State do
    @enforce_keys [:temp_ratio, :pump_ratio]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.Operator, as: Op
  alias AutoNuke.Operator.CoreFactor.Drift

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Allowed core factor range:
  @min_core_factor 2.0
  @max_core_factor 5.0
  # Max drift rates, in core factor per hour:
  @increase_rate 1.0
  @decrease_rate 0.2

  # Grab relevant ranges:
  @temp_range Op.CorePower.temp_range()
  @pump_range Op.CoreTemp.pump_speed_range()

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(_) do
    state = %State{temp_ratio: nil, pump_ratio: nil}
    PubSub.subscribe(self(), :ticker)
    PubSub.subscribe(self(), :core_temp)
    Logger.info(@log_prefix <> "Started.")
    {:ok, state}
  end

  @impl true
  def handle_info({:core_temp, temp_target, pump_speed}, _) do
    {:noreply,
     %State{
       temp_ratio: portion_of_range(temp_target, @temp_range),
       pump_ratio: portion_of_range(pump_speed, @pump_range)
     }}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{temp_ratio: nil, pump_ratio: nil} = state) do
    Logger.warning(@log_prefix <> "No core temperature data received yet.")
    {:noreply, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    case Op.CoreFactor.get_drift() do
      nil -> maybe_drift(nil, state)
      {%Drift{mode: :auto} = drift, _} -> maybe_drift(drift, state)
      {%Drift{}, _} -> :noop
    end

    {:noreply, state}
  end

  defp maybe_drift(old_drift, %State{} = state) do
    old_direction = read_drift_direction(old_drift)
    new_direction = calculate_needed_direction(state)
    if old_direction != new_direction, do: drift(new_direction)
    state
  end

  defp drift(:hold), do: Op.CoreFactor.stop_drift()

  defp drift(direction) do
    old_factor = Op.CoreFactor.get_target()

    new_factor =
      case direction do
        :increase -> old_factor + @increase_rate
        :decrease -> old_factor - @decrease_rate
      end
      |> clamp(@min_core_factor, @max_core_factor)

    if new_factor != old_factor do
      Op.CoreFactor.drift(
        start_factor: old_factor,
        end_factor: new_factor,
        duration: 60,
        mode: :auto
      )
    end
  end

  defp read_drift_direction(nil), do: :hold
  defp read_drift_direction(%Drift{start_factor: s, end_factor: e}) when s < e, do: :increase
  defp read_drift_direction(%Drift{start_factor: s, end_factor: e}) when s > e, do: :decrease

  defp calculate_needed_direction(%State{pump_ratio: pumps}) do
    cond do
      pumps < 0.20 -> :increase
      pumps > 0.80 -> :decrease
      true -> :hold
    end
  end

  defp portion_of_range(value, left..right//1) do
    (value - left) / (right - left)
  end

  defp clamp(value, min, max) when min < max do
    value
    |> max(min)
    |> min(max)
  end
end
