defmodule AutoNuke.Operator.SteamFlow.DemandTracker do
  @enforce_keys [:timestamp, :demand_kwh, :supplied_kwh, :supply_per_second]
  defstruct(@enforce_keys)
  alias __MODULE__, as: DT

  alias AutoNuke.API
  alias AutoNuke.Smoother

  @seconds_per_minute AutoNuke.Ticker.seconds_per_minute()

  # Final supply should be between 100% and 110% of the hour's demand.
  # The game accepts 90% and 110%, but our API-based math may not be perfect.
  @lower_limit 1.0
  @upper_limit 1.10

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

  def target_and_deadzone(%DT{timestamp: ts, supplied_kwh: supply, demand_kwh: demand}) do
    lower_kw = (demand * @lower_limit - supply) / hour_remaining_percent(ts)
    upper_kw = (demand * @upper_limit - supply) / hour_remaining_percent(ts)

    lower_ratio = lower_kw / demand
    upper_ratio = upper_kw / demand

    target = (upper_ratio + lower_ratio) / 2
    deadzone = (upper_ratio - lower_ratio) / 2

    target =
      if API.Power.get_active_resistor_kw() > 0 do
        # No point in overproducing if it's just going to get eaten by resistors.
        # However, seems like even with resistors active, we satisfy about 101.7% of demand.
        # So hedge our bets and try 102% here.
        min(target, 1.02)
      else
        target
      end

    {target, deadzone}
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

  # On start, assume that we've supplied 100% of the demand for as much of the
  # hour as has elapsed so far.
  defp guess_supplied_kwh(timestamp, demand_kwh),
    do: hour_elapsed_percent(timestamp) * demand_kwh

  defp hour_elapsed_percent(timestamp), do: rem(timestamp, 60) / 60
  defp hour_remaining_percent(timestamp), do: 1.0 - hour_elapsed_percent(timestamp)
end
