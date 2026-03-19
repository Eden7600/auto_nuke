defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:target, :axis, :current_temp, :temp_history, :roc_smoothed]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.Smoother
  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Core temperature tends to have semi-rare transient spikes depending on read timing.
  # To mitigate this, use the median of the last 3 readings.
  @current_temp_size 3
  # Then, measure one minute's worth of history, to calculate rate-of-change.
  @temp_history_size AutoNuke.Ticker.ticks_per_minute()
  # And smooth that over the past minute as well:
  @roc_smoothed_size AutoNuke.Ticker.ticks_per_minute()

  # Goals:
  #   - when off by 1°C, target 0.2°C/minute (or 5 minutes per degree change)
  #   - when off by 10°C, target ~1°C/minute
  #   - when off by 300°C, target ~30°C/minute
  #
  # The formula that roughly matches this:
  #
  #   f(x) = 0.2 * x^0.7
  #
  # Additionally:
  #   - minimum speed: 0.1°C/minute
  @dpm_minimum 0.1
  #   - deadzone: when error < 0.1°C, target full stop (0°C/min)
  @error_deadzone 0.1

  defp dpm_per_degree(error) when error >= 0, do: (0.2 * error ** 0.7) |> max(@dpm_minimum)
  defp dpm_per_degree(error) when error < 0, do: -dpm_per_degree(abs(error))

  defp target_degrees_per_minute(error) do
    case abs(error) <= @error_deadzone do
      true -> 0.0
      false -> dpm_per_degree(error)
    end
  end

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
        kd: 0.0005,
        deadzone: 0.05,
        to_value_fn: &axis_to_rods/1,
        offset: rods |> rods_to_axis(),
        initial_value: rods
      )

    state =
      %State{
        target: target,
        current_temp: Smoother.new(@current_temp_size) |> Smoother.add(temp),
        temp_history: Smoother.new(@temp_history_size) |> Smoother.add(temp),
        roc_smoothed: Smoother.new(@roc_smoothed_size),
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
    current_temp = state.current_temp |> Smoother.add(get_temperature())
    temp = Smoother.median(current_temp)
    error = state.target - temp

    temp_history = state.temp_history |> Smoother.add(temp)
    roc_smoothed = state.roc_smoothed |> Smoother.add(Smoother.rate_of_change(state.temp_history))

    roc_current = Smoother.average(roc_smoothed)
    roc_target = target_degrees_per_minute(error)

    case ControlAxis.step(state.axis, roc_target, roc_current) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing rods from #{old} to #{new}.")
        set_rods(new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply,
       %State{
         state
         | axis: axis,
           current_temp: current_temp,
           temp_history: temp_history,
           roc_smoothed: roc_smoothed
       }}
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
