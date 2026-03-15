defmodule AutoNuke.Operator.TurbineBypass do
  use GenServer
  require Logger

  alias AutoNuke.Smoother

  defmodule State do
    # Give us the average of the last 5 ticks (1 sec) of generation:
    @generator_smoothing 5

    @enforce_keys [:axis, :limiter]
    defstruct(
      axis: nil,
      limiter: nil,
      smoothed_generation: Smoother.new(@generator_smoothing)
    )
  end

  alias AutoNuke.ControlAxis
  alias AutoNuke.Operator.TurbineBypass.TorqueLimiter

  @log_prefix "[#{inspect(__MODULE__)}] "

  @target_percent 0.975
  @deadzone 0.025

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    limiter = TorqueLimiter.new(2)
    bypass = limiter.bypass_wanted

    axis =
      ControlAxis.new(
        kp: 1,
        ki: 0.1,
        deadzone: @deadzone,
        to_value_fn: &axis_to_bypass/1,
        offset: bypass |> bypass_to_axis(),
        initial_value: bypass
      )

    state = %State{
      limiter: limiter,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with bypass #{bypass}%.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{axis: axis} = state) do
    {ratio, %State{} = state} = get_demand_ratio(state)

    case ControlAxis.step(axis, @target_percent, ratio) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing bypass from #{old} to #{new}.")
        limiter = TorqueLimiter.set_bypass(state.limiter, new)
        %State{state | axis: axis, limiter: limiter}

      {:unchanged, axis, _old_value} ->
        limiter = TorqueLimiter.check_torque(state.limiter)
        %State{state | axis: axis, limiter: limiter}
    end
    |> then(fn %State{} = new_state ->
      {:noreply, new_state}
    end)
  end

  defp get_demand_ratio(%State{smoothed_generation: smoothed} = state) do
    smoothed = smoothed |> Smoother.add(get_generation_kw())

    generated_kw = Smoother.average(smoothed)
    used_kw = AutoNuke.API.get_float("POWER_FROM_TURBINE_KW")
    demand_kw = AutoNuke.API.get_float("POWER_DEMAND_MW") * 1000
    ratio = (generated_kw - used_kw) / demand_kw

    {ratio, %State{state | smoothed_generation: smoothed}}
  end

  defp get_generation_kw do
    # TODO: add other generators
    AutoNuke.API.get_float("GENERATOR_2_KW")
  end

  def axis_to_bypass(output), do: round(50 - output * 50)
  def bypass_to_axis(bypass), do: (50 - bypass) / 50
end
