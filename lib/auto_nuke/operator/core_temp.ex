defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:target, :axis, :last_temp]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Rods take time to move.  Try to keep our ordered rod height within 1% of actual.
  @rods_clamping 1.0

  def start_link(opts) do
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
    temp = get_temperature()
    target = target || temp

    axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.001,
        kd: 0.0001,
        deadzone: 0.1,
        to_value_fn: &axis_to_rods/1,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        target: target,
        last_temp: temp,
        axis: axis
      }

    PubSub.subscribe(self(), :ticker)

    Logger.info(
      @log_prefix <> "Started with temperature #{temp}°C, target #{target}°C, rods at #{rods}%."
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:target, t}, %State{} = state) do
    Logger.info(@log_prefix <> "Core target changed from #{state.target}°C to #{t}°C.")

    {:noreply, %State{state | target: t}}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    temp = get_verified_temperature([state.last_temp])

    case ControlAxis.step(state.axis, state.target, temp) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing rods from #{old} to #{new}.")
        set_rods(new)
        maybe_clamp(axis, new)

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis, last_temp: temp}}
    end)
  end

  defp get_temperature(), do: API.get_float("CORE_TEMP")

  defp get_verified_temperature(seen) when is_list(seen) do
    # Temperature has a tendency to have tiny little spikes depending on read timing.
    # To mitigate this and try to hold a steady state, if we detect a temperature change,
    # we take extra readings until they agree.
    temp = get_temperature()

    if temp in seen do
      temp
    else
      get_verified_temperature([temp | seen])
    end
  end

  # Assumption: Any core with an installed fuel cell will have control rods.
  defp get_rods do
    1..9
    |> Enum.map(fn core ->
      case API.get_string("CORE_BAY_#{core}_STATE") do
        "INTERIOR" -> API.get_float("ROD_BANK_POS_#{core - 1}_ACTUAL")
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Statistex.average()
  end

  defp set_rods(value) when value >= 0.0 and value <= 100.0 do
    AutoNuke.API.put("RODS_ALL_POS_ORDERED", value)
  end

  defp axis_to_rods(output), do: (50 - output * 50) |> Float.round(1)
  defp rods_to_axis(rods), do: ((50 - rods) / 50) |> Float.round(5)

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
