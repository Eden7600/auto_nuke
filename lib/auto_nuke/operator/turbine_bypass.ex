defmodule AutoNuke.Operator.TurbineBypass do
  use GenServer
  require Logger

  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] "

  @target_percent 0.975
  @deadzone 0.025

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    bypass = get_bypass()

    axis =
      ControlAxis.new(
        kp: 1,
        ki: 0.1,
        deadzone: @deadzone,
        to_value_fn: &axis_to_bypass/1,
        offset: bypass |> bypass_to_axis(),
        initial_value: bypass
      )

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with bypass #{bypass}%.")
    {:ok, axis}
  end

  @impl true
  def handle_info({:tick, _}, axis) do
    case ControlAxis.step(axis, @target_percent, get_demand_ratio()) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing bypass from #{old} to #{new}.")
        set_bypass(new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      {:noreply, axis}
    end)
  end

  defp get_demand_ratio do
    generated_kw = AutoNuke.API.get_float("GENERATOR_2_KW")
    used_kw = AutoNuke.API.get_float("POWER_FROM_TURBINE_KW")
    demand_kw = AutoNuke.API.get_float("POWER_DEMAND_MW") * 1000
    (generated_kw - used_kw) / demand_kw
  end

  defp get_bypass do
    AutoNuke.API.get_integer("STEAM_TURBINE_2_BYPASS_ACTUAL")
  end

  defp set_bypass(value) do
    AutoNuke.API.put("STEAM_TURBINE_2_BYPASS_ORDERED", value)
  end

  def axis_to_bypass(output), do: round(25 - output * 25)
  def bypass_to_axis(bypass), do: (25 - bypass) / 25
end
