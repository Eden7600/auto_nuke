defmodule AutoNuke.Operator.SteamFlow.DemandTracker do
  @enforce_keys [:timestamp, :demand_kwh, :supplied_kwh, :supply_per_second]
  defstruct(@enforce_keys)
  alias __MODULE__, as: DT

  alias AutoNuke.API
  alias AutoNuke.Smoother

  @seconds_per_minute AutoNuke.Ticker.seconds_per_minute()

  # Final supply should be between 91% and 109% of the hour's demand.
  # The game accepts 90% and 110%, but our API-based math may not be perfect.
  @lower_limit 0.91
  @upper_limit 1.09

  # Minimum and maximum targets, as a percentage of the current demand.
  # This means that if we spend much of the hour under- or over-procuding,
  # we won't end up with ludicrously high / negative targets.
  #
  # The lower limit can't go negative, and it can't go higher than 300% the current demand.
  @min_lower_limit 0.0
  @max_lower_limit 3.0
  # The upper limit can go as high as needed, but can't go below 25% demand.
  @min_upper_limit 0.25
  @max_upper_limit 10000

  def new do
    timestamp = API.Misc.get_time_stamp()
    demand_kwh = API.Power.get_demand_kw()
    supplied_kwh = guess_supplied_kwh(timestamp, demand_kwh)

    %DT{
      timestamp: timestamp,
      demand_kwh: demand_kwh,
      supplied_kwh: supplied_kwh,
      supply_per_second: Smoother.new(@seconds_per_minute)
    }
  end

  defp target_kw_range(%DT{timestamp: ts, supplied_kwh: supply, demand_kwh: demand}) do
    lower =
      ((demand * @lower_limit - supply) / hour_remaining_percent(ts))
      |> clamp(demand * @min_lower_limit, demand * @max_lower_limit)

    upper =
      ((demand * @upper_limit - supply) / hour_remaining_percent(ts))
      |> clamp(demand * @min_upper_limit, demand * @max_upper_limit)

    target =
      ((demand - supply) / hour_remaining_percent(ts))
      |> clamp(lower, upper)

    {lower, target, upper}
  end

  def target_ratio_range(%DT{demand_kwh: demand} = dt) do
    {lower, target, upper} = target_kw_range(dt)
    {lower / demand, target / demand, upper / demand}
  end

  def current_ratio(%DT{demand_kwh: demand}, supply), do: supply / demand

  def tick(%DT{} = dt, current_supply) do
    old_ts = dt.timestamp
    new_ts = API.Misc.get_time_stamp()
    old_hour = div(old_ts, 60)
    new_hour = div(new_ts, 60)

    dt
    |> add_supply(current_supply)
    |> tick_minute(new_ts)
    |> tick_hour(old_hour, new_hour)
  end

  defp tick_minute(%DT{timestamp: same} = dt, same), do: dt

  defp tick_minute(%DT{supply_per_second: sps} = dt, new_ts) do
    average_supply = Smoother.average(sps)

    %DT{
      dt
      | timestamp: new_ts,
        supplied_kwh: dt.supplied_kwh + average_supply / 60.0,
        supply_per_second: Smoother.new(@seconds_per_minute)
    }
  end

  defp tick_hour(%DT{} = dt, same, same), do: dt

  defp tick_hour(%DT{} = dt, _, _) do
    %DT{dt | demand_kwh: API.Power.get_demand_kw(), supplied_kwh: 0}
  end

  defp add_supply(%DT{demand_kwh: demand_kwh, supply_per_second: sps} = dt, supply_kwh) do
    supply_kwh = limit_resistors(supply_kwh, demand_kwh)
    %DT{dt | supply_per_second: sps |> Smoother.add(supply_kwh)}
  end

  defp limit_resistors(supply_kw, demand_kw) when supply_kw <= demand_kw, do: supply_kw

  defp limit_resistors(supply_kw, demand_kw) when supply_kw > demand_kw do
    max(
      supply_kw - API.Power.get_active_resistor_kw(),
      demand_kw
    )
  end

  # On start, assume that we've supplied 90% of the demand for as much of the
  # hour as has elapsed so far.
  defp guess_supplied_kwh(timestamp, demand_kwh),
    do: hour_elapsed_percent(timestamp) * demand_kwh * 0.90

  defp hour_elapsed_percent(timestamp), do: rem(timestamp, 60) / 60
  defp hour_remaining_percent(timestamp), do: 1.0 - hour_elapsed_percent(timestamp)

  defp clamp(n, min, max) do
    n
    |> max(min)
    |> min(max)
  end
end
