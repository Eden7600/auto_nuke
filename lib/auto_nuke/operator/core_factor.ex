defmodule AutoNuke.Operator.CoreFactor do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:target, :axis, :smoothed]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Average the core factor over the past three in-game minutes:
  @core_factor_smoothing AutoNuke.Ticker.ticks_per_minute() * 3
  # Rods take time to move.  Try to keep our ordered rod height within 1% of actual.
  @rods_clamping 1.0

  def start_link(opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, target, opts)
  end

  def set_target(target, pid \\ __MODULE__) do
    GenServer.cast(pid, {:target, target})
  end

  @impl true
  def init(target) when is_number(target) or is_nil(target) do
    rods = get_rods()
    factor = get_core_factor()
    target = target || factor

    axis =
      ControlAxis.new(
        kp: 0.02,
        ki: 0.002,
        deadzone: 0.1,
        to_value_fn: &axis_to_rods/1,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        target: target,
        axis: axis,
        smoothed: Smoother.new(@core_factor_smoothing)
      }

    PubSub.subscribe(self(), :ticker)

    Logger.info(
      @log_prefix <> "Started with core factor #{factor}°C, target #{target}°C, rods at #{rods}%."
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:target, t}, %State{} = state) do
    Logger.info(@log_prefix <> "Core factor target changed from #{state.target} to #{t}.")
    {:noreply, %State{state | target: t}}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    factor = get_core_factor()
    smoothed = state.smoothed |> Smoother.add(factor)
    current = Smoother.average(smoothed)

    case ControlAxis.step(state.axis, state.target, current) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing rods from #{old} to #{new}.")
        set_rods(new)
        maybe_clamp(axis, new)

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis, smoothed: smoothed}}
    end)
  end

  defp get_core_factor, do: API.get_float("CORE_FACTOR")
  defp get_rods, do: API.get_float("RODS_POS_ACTUAL")

  defp set_rods(value) when value >= 0.0 and value <= 100.0,
    do: API.put("RODS_ALL_POS_ORDERED", value)

  defp axis_to_rods(output), do: (50 - output * 50) |> Float.round(1)
  defp rods_to_axis(rods), do: (50 - rods) / 50

  defp maybe_clamp(axis, ordered) do
    actual = get_rods()

    cond do
      ordered - actual > @rods_clamping ->
        # We're asking for too much rods at once, clamp down.
        Logger.debug(@log_prefix <> "Clamping down to #{actual + @rods_clamping}")
        clamp_to = (actual + @rods_clamping) |> rods_to_axis()
        axis |> ControlAxis.clamp_min(clamp_to)

      actual - ordered > @rods_clamping ->
        # We're asking for too little rods at once, clamp up.
        Logger.debug(@log_prefix <> "Clamping up to #{actual - @rods_clamping}")
        clamp_to = (actual - @rods_clamping) |> rods_to_axis()
        axis |> ControlAxis.clamp_max(clamp_to)

      true ->
        axis
    end
  end
end
