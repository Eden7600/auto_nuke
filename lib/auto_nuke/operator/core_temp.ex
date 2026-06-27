defmodule AutoNuke.Operator.CoreTemp do
  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Operator.CoreTemp.Drift
  alias AutoNuke.Time, as: ANTime

  defmodule State do
    @enforce_keys [:monitored, :axis]
    defstruct(
      monitored: nil,
      axis: nil,
      override: nil,
      drift: nil
    )
  end

  defmodule MonitoredVessel do
    @enforce_keys [:loop, :vessel, :history]
    defstruct(@enforce_keys)

    alias __MODULE__, as: MV
    alias AutoNuke.Smoother

    @history_size 10
    @lookahead 5

    def new(loop) do
      vessel = API.Vessels.steam_generator(loop)
      pressure = API.Vessels.get_pressure(vessel)

      %MV{
        loop: loop,
        vessel: vessel,
        history: Smoother.new(@history_size) |> Smoother.add(pressure)
      }
    end

    def tick(%MV{vessel: vessel, history: history} = mv) do
      pressure = API.Vessels.get_pressure(vessel)
      %MV{mv | history: history |> Smoother.add(pressure)}
    end

    def guess_future_pressure(%MV{history: h}), do: h |> Smoother.extrapolate(@lookahead)
  end

  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Target 60 bar of pressure, plus or minus half a bar.
  @target_pressure 60
  @deadzone 0.5

  # Temperature range: 300°C to 400°C.
  @temp_range 300..400
  # We could probably go lower, but I don't want to risk turbine stalls.
  def temp_range, do: @temp_range

  # Clamp values to within +10°C or -5°C of current temperature.
  @clamp_upwards 10
  @clamp_downwards 5
  # If we get within 10°C of the edge of @temp_range, clamp to
  # half the difference between current temperature and that boundary.
  @clamp_near_boundary 10

  def start_link(opts \\ []) do
    {loops, opts} = Keyword.pop(opts, :loops, :detect)
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, loops, opts)
  end

  def set_override(temp, expiry \\ :next_hour, pid \\ __MODULE__) do
    GenServer.call(pid, {:override, temp + 0.0, ANTime.parse_expiry(expiry)})
  end

  def clear_override(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_override)
  end

  def drift(opts, pid \\ __MODULE__) do
    opts
    |> Keyword.put_new(:start_time, :now)
    |> Drift.new()
    |> then(&GenServer.call(pid, {:drift, &1}))
  end

  def stop_drift(pid \\ __MODULE__) do
    GenServer.call(pid, :stop_drift)
  end

  @impl true
  def init(:detect) do
    AutoNuke.Operator.SteamFlow.get_closed_breakers()
    |> init()
  end

  @impl true
  def init(loops) when is_list(loops) do
    temp = get_core_temp()
    monitored = loops |> Enum.map(&MonitoredVessel.new/1)

    axis =
      ControlAxis.new(
        kp: 0.01,
        ki: 0.0005,
        deadzone: @deadzone,
        to_value_fn: &axis_to_temp/1,
        offset: temp |> temp_to_axis(),
        initial_value: temp
      )

    state = %State{monitored: monitored, axis: axis}

    PubSub.subscribe(self(), :ticker)

    Logger.info([
      @log_prefix,
      "Started with loops #{inspect(loops)}",
      " and temperature #{inspect(temp)}°C."
    ])

    {:ok, state}
  end

  @impl true
  def handle_call({:override, temp, expiry}, _from, %State{} = state) when is_float(temp) do
    expires_desc =
      case expiry do
        :never -> "does not expire"
        ts -> "expires at #{ANTime.timestamp_to_string(ts)}"
      end

    Logger.info(@log_prefix <> "Override set to #{temp}°C, #{expires_desc}.")
    {:reply, :ok, %State{state | override: {temp, expiry}}}
  end

  @impl true
  def handle_call(:clear_override, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Clearing override.")
    {:reply, :ok, %State{state | override: nil}}
  end

  @impl true
  def handle_call({:drift, %Drift{} = drift}, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Now planning to drift #{Drift.describe(drift)}.")
    {:reply, :ok, %State{state | drift: {drift, false}}}
  end

  @impl true
  def handle_call(:stop_drift, _from, %State{} = state) do
    Logger.info(@log_prefix <> "Cancelling drift.")
    {:reply, :ok, %State{state | drift: nil}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state =
      state
      |> apply_drift()
      |> maybe_expire_override()

    monitored = state.monitored |> Enum.map(&MonitoredVessel.tick/1)
    future_pressure = get_future_pressure(monitored)

    case ControlAxis.step(state.axis, @target_pressure, future_pressure) do
      {:changed, axis, new, _old} ->
        publish_core_temp(axis, new, state.override)

      {:unchanged, axis, old} ->
        publish_core_temp(axis, old, state.override)
    end
    |> then(fn axis ->
      {:noreply, %State{state | axis: axis, monitored: monitored}}
    end)
  end

  defp apply_drift(%State{drift: nil} = state), do: state

  defp apply_drift(%State{drift: {%Drift{} = drift, started}} = state) do
    case Drift.current_value(drift) do
      :not_started ->
        state

      {:drifting, :current} ->
        temp = state.axis.last_value
        drift = %Drift{drift | start_time: temp}
        Logger.info(@log_prefix <> "Starting drift #{Drift.describe(drift)} ...")
        %State{state | override: {temp, :never}, drift: {drift, true}}

      {:drifting, temp} ->
        case started do
          false ->
            Logger.info(@log_prefix <> "Starting drift #{Drift.describe(drift)} ...")
            %State{state | override: {temp, :never}, drift: {drift, true}}

          true ->
            %State{state | override: {temp, :never}}
        end

      {:complete, temp} ->
        %State{state | override: {temp, :never}, drift: nil}
    end
  end

  defp maybe_expire_override(%State{override: nil} = state), do: state
  defp maybe_expire_override(%State{override: {_, :never}} = state), do: state

  defp maybe_expire_override(%State{override: {_, ts}} = state) when is_integer(ts) do
    if ANTime.get_current_time() >= ts do
      Logger.notice(@log_prefix <> "Override has expired.")
      %State{state | override: nil}
    else
      state
    end
  end

  defp publish_core_temp(axis, _wanted, {override, _expires}) do
    PubSub.publish(:core_temp, {:core_temp, override})
    ControlAxis.clamp(axis, temp_to_axis(override), override)
  end

  defp publish_core_temp(axis, wanted, nil) do
    current = get_core_temp()
    min_temp = min_relative(current) |> clamp_to_range(@temp_range)
    max_temp = max_relative(current) |> clamp_to_range(@temp_range)

    {action, new_temp} =
      cond do
        wanted < min_temp -> {:clamp, min_temp}
        wanted > max_temp -> {:clamp, max_temp}
        true -> {:allow, wanted}
      end

    PubSub.publish(:core_temp, {:core_temp, new_temp})

    case action do
      :allow -> axis
      :clamp -> ControlAxis.clamp(axis, temp_to_axis(new_temp), new_temp)
    end
  end

  @relative_low @temp_range.first + @clamp_near_boundary
  @relative_high @temp_range.last - @clamp_near_boundary

  defp min_relative(temp) when temp < @relative_low do
    # Half of the distance to the lower bound:
    temp - (temp - @temp_range.first) / 2
  end

  defp min_relative(temp), do: temp - @clamp_downwards

  defp max_relative(temp) when temp > @relative_high do
    # Half of the distance to the upper bound:
    temp + (@temp_range.last - temp) / 2
  end

  defp max_relative(temp), do: temp + @clamp_upwards

  defp clamp_to_range(value, low..high//_) when is_float(value) do
    value
    |> max(low)
    |> min(high)
    |> Kernel.+(0.0)
  end

  defp get_future_pressure([]) do
    # No active loops, reactor idle.  Pretend current pressure is a bit too
    # high, so we slowly slew our target temperature towards the minimum.
    @target_pressure + @deadzone * 1.1
  end

  defp get_future_pressure(monitored) do
    monitored
    |> Enum.map(&MonitoredVessel.guess_future_pressure/1)
    |> Statistex.average()
  end

  defp get_core_temp do
    API.Vessels.core_vessel()
    |> API.Vessels.get_temperature()
  end

  @temp_span (@temp_range.last - @temp_range.first) / 2
  @temp_midpoint @temp_range.first + @temp_span
  defp axis_to_temp(output), do: (@temp_midpoint + output * @temp_span) |> Float.round(2)
  defp temp_to_axis(temp), do: (temp - @temp_midpoint) / @temp_span
end
