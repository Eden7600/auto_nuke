defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:core, :target, :axis, :last_n_temps]
    defstruct(@enforce_keys)
  end

  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] "

  def start_link(opts) do
    {core, opts} = Keyword.pop!(opts, :core)
    {target, opts} = Keyword.pop(opts, :target)
    GenServer.start_link(__MODULE__, {core, target}, opts)
  end

  def set_target(pid, target) do
    GenServer.cast(pid, {:target, target})
  end

  @impl true
  def init({core, target}) when (core in 1..9 and is_number(target)) or is_nil(target) do
    rods = get_rods(core)
    temp = get_temperature(core)
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
        core: core,
        target: target,
        last_n_temps: [temp],
        axis: axis
      }

    PubSub.subscribe(self(), :ticker)

    Logger.info(
      @log_prefix <> "Started with temperature #{temp}°C, target #{target}°C, rods at #{rods}%."
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:target, t}, state) do
    Logger.info(
      @log_prefix <> "Core #{state.core} target changed from #{state.target}°C to #{t}°C."
    )

    {:noreply, %State{state | target: t}}
  end

  @impl true
  def handle_info({:tick, _}, %State{core: core} = state) do
    {temp, last_n} = get_smoothed_temperature(core, state.last_n_temps)

    case ControlAxis.step(state.axis, state.target, temp) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing core #{core} rods from #{old} to #{new}.")
        set_rods(core, new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis, last_n_temps: last_n}}
    end)
  end

  @temp_count 3

  defp get_smoothed_temperature(core, last_n) do
    temp = get_temperature(core)
    last_n = [temp | Enum.take(last_n, @temp_count - 1)]
    middle_index = Enum.count(last_n) |> div(2)
    median = last_n |> Enum.sort() |> Enum.at(middle_index)

    {median, last_n}
  end

  defp get_temperature(core) when core in 1..9 do
    AutoNuke.API.get_float("CORE_FUEL_#{core}_TEMPERATURE")
  end

  defp get_rods(core) do
    AutoNuke.API.get_float("ROD_BANK_POS_#{core - 1}_ORDERED")
    |> Float.round(1)
  end

  defp set_rods(core, value) when value >= 0.0 and value <= 100.0 do
    AutoNuke.API.put("ROD_BANK_POS_#{core - 1}_ORDERED", value)
  end

  defp axis_to_rods(output), do: (50 - output * 50) |> Float.round(1)
  defp rods_to_axis(rods), do: ((50 - rods) / 50) |> Float.round(5)
end
