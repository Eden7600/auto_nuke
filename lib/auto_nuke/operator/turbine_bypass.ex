defmodule AutoNuke.Operator.TurbineBypass do
  use GenServer
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Smoother

  defmodule State do
    # Give us the average of the last 5 ticks (1 sec) of generation:
    @generator_smoothing 5

    @enforce_keys [:axis, :limiters]
    defstruct(
      axis: nil,
      limiters: nil,
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
    get_connected_loops()
    |> do_init()
  end

  defp do_init([]) do
    Logger.info(@log_prefix <> "No loops connected, started in sleep mode.")
    {:ok, %State{limiters: [], axis: nil}}
  end

  defp do_init(loops) when is_list(loops) do
    limiters = loops |> Enum.map(&TorqueLimiter.new/1)

    bypass =
      limiters
      |> Enum.map(& &1.bypass_wanted)
      |> Statistex.average()

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
      limiters: limiters,
      axis: axis
    }

    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Started with loops #{inspect(loops)} at bypass #{bypass}%.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{axis: axis} = state) do
    {ratio, %State{} = state} = get_demand_ratio(state)

    case ControlAxis.step(axis, @target_percent, ratio) do
      {:changed, axis, new, old} ->
        Logger.info(@log_prefix <> "Changing bypass from #{old} to #{new}.")
        limiters = state.limiters |> Enum.map(&TorqueLimiter.set_bypass(&1, new))
        %State{state | axis: axis, limiters: limiters}

      {:unchanged, axis, _old_value} ->
        limiters = state.limiters |> Enum.map(&TorqueLimiter.check_torque(&1))
        %State{state | axis: axis, limiters: limiters}
    end
    |> then(fn %State{} = new_state ->
      {:noreply, new_state}
    end)
  end

  defp get_demand_ratio(%State{smoothed_generation: smoothed} = state) do
    smoothed = smoothed |> Smoother.add(get_generation_kw(state))

    generated_kw = Smoother.average(smoothed)
    used_kw = API.get_float("POWER_FROM_TURBINE_KW")
    demand_kw = API.get_float("POWER_DEMAND_MW") * 1000
    ratio = (generated_kw - used_kw) / demand_kw

    {ratio, %State{state | smoothed_generation: smoothed}}
  end

  defp get_connected_loops do
    1..3
    |> Enum.reject(fn loop ->
      # True if breaker open, i.e. disconnected.
      API.get_boolean("GENERATOR_#{loop - 1}_BREAKER")
    end)
  end

  defp get_generation_kw(%State{limiters: limiters}) do
    limiters
    |> Enum.map(fn %TorqueLimiter{loop: loop} ->
      API.get_float("GENERATOR_#{loop - 1}_KW")
    end)
    |> Enum.sum()
  end

  def axis_to_bypass(output), do: round(50 - output * 50)
  def bypass_to_axis(bypass), do: (50 - bypass) / 50
end
