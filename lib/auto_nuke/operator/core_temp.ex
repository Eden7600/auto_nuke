defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:target, :axis, :smoothed_temp]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.Smoother
  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Core temperature tends to have semi-rare transient spikes depending on read timing.
  # To mitigate this, use the median of the last 5 readings (~1 second at normal speed).
  @temp_smoothing 5

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
        kp: 0.02,
        kd: 0.01,
        ki: 0.0001,
        deadzone: 0.2,
        to_value_fn: &axis_to_rods/1,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        target: target,
        smoothed_temp: Smoother.new(@temp_smoothing) |> Smoother.add(temp),
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
    smoother = state.smoothed_temp |> Smoother.add(get_temperature())
    temp = Smoother.median(smoother)

    case ControlAxis.step(state.axis, state.target, temp) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing rods from #{old} to #{new}.")
        set_rods(new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis, smoothed_temp: smoother}}
    end)
  end

  defp get_temperature, do: API.get_float("CORE_TEMP")

  # Assumption: Any core with an installed fuel cell will have control rods.
  defp get_rods do
    1..9
    |> Enum.map(fn core ->
      case API.get_string("CORE_BAY_#{core}_STATE") do
        "INTERIOR" -> API.get_float("ROD_BANK_POS_#{core - 1}_ORDERED")
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
end
