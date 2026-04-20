defmodule AutoNuke.Operator.SteamFlow.DemandTracker do
  @enforce_keys [:timestamp, :demand_kwh, :supplied_kwh, :supply_per_second]
  defstruct(@enforce_keys)
  alias __MODULE__, as: DT

  alias AutoNuke.API
  alias AutoNuke.Smoother

  @seconds_per_minute AutoNuke.Ticker.seconds_per_minute()

  # Final supply should be between 95% and 105% of the hour's demand.
  # The game accepts 90% and 110%, but our API-based math may not be perfect.
  @lower_limit 0.95
  @upper_limit 1.05

  # At the top of the hour, target will be 100% w/ a 5% deadzone, per above.
  #
  # Left unchecked, deadzone will naturally grow to 150% by the end of the
  # hour — by the time you reach the last few minutes, there's very little you
  # can realistically do to mess up (or correct) the total supplied energy.
  #
  # However, this growth is not symmetrical.  If we are regularly sitting to
  # one side of the target, then the far side of the range will expand faster
  # than the near side.  This pushes our target (the midpoint of the range)
  # further away, which further ensures we stay to the same side of the target.
  #
  # Left unchecked, this can lead to our target becoming awkwardly huge
  # (over 200%) or impossibly low (under 0%, i.e. we'd need to _take back_
  # energy rather than deliver it).  Both of these are undesirable since they
  # lead to a lot of pointless SteamFlow fussing at the end of the hour.
  #
  # It's nice that the deadzone expands, as it means that SteamFlow's PID
  # controller has more room to breathe and doesn't need to "hunt" the target
  # as tightly.  But 15% is plenty of room, and putting a limit on the deadzone
  # will prevent our target from ever dropping too low or pushing too high, so
  # long as our production reliably stays within the deadzone.
  @max_deadzone 0.15

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

    {target, deadzone |> min(@max_deadzone)}
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
end
