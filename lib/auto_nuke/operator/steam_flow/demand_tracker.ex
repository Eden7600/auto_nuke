defmodule AutoNuke.Operator.SteamFlow.DemandTracker do
  require Logger

  @enforce_keys [:timestamp, :demand_kwh, :supplied_kwh, :supply_per_second]
  defstruct(@enforce_keys ++ [recent_rate: nil])
  alias __MODULE__, as: DT

  alias AutoNuke.API
  alias AutoNuke.Smoother

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  @seconds_per_minute AutoNuke.Ticker.seconds_per_minute()

  # Standard mode: 95% to 110%, ideal 105%, no cap.
  @standard_targets %{
    min: 0.95,
    max: 1.10,
    ideal: 1.05,
    hard_cap: 99999.0
  }

  # With resistors enabled: 95% to 110%, ideal 100%, hard cap target to 102%.
  @resistor_targets %{
    min: 0.95,
    max: 1.10,
    ideal: 1.00,
    hard_cap: 1.02
  }

  @min_deadzone 0.01
  @min_deadzone_kw 10000
  @max_deadzone 0.5

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

  def target_and_deadzone(%DT{} = dt) do
    case API.Power.get_active_resistor_kw() > 0 do
      true -> @resistor_targets
      false -> @standard_targets
    end
    |> target_and_deadzone(dt)
  end

  defp target_and_deadzone(
         %{min: min_supply, max: max_supply, ideal: ideal, hard_cap: hard_cap},
         %DT{timestamp: ts, supplied_kwh: supply, demand_kwh: demand}
       ) do
    remaining = hour_remaining_percent(ts)
    lower_kw = (demand * min_supply - supply) / remaining
    upper_kw = (demand * max_supply - supply) / remaining

    upper_kw =
      if upper_kw - lower_kw < @min_deadzone_kw do
        lower_kw + @min_deadzone_kw
      else
        upper_kw
      end

    lower_ratio = lower_kw / demand
    upper_ratio = upper_kw / demand

    target =
      if lower_ratio <= ideal && upper_ratio >= ideal do
        ideal
      else
        push_into_range(ideal, lower_ratio, upper_ratio, demand)
      end

    target =
      if target > hard_cap do
        Logger.warning(
          "Resistors enabled: Hard-capped from #{round(target * 100)}% to #{round(hard_cap * 100)}%."
        )

        hard_cap
      else
        target
      end

    upper_deadzone = (upper_ratio - target) |> clamp_deadzone()
    lower_deadzone = (target - lower_ratio) |> clamp_deadzone()

    {target, {upper_deadzone, lower_deadzone}}
  end

  defp clamp_deadzone(dz) when dz > @max_deadzone, do: @max_deadzone
  defp clamp_deadzone(dz) when dz < @min_deadzone, do: @min_deadzone
  defp clamp_deadzone(dz), do: dz

  defp push_into_range(ideal, lower, upper, demand) when ideal < lower do
    # Push 10% above lower, or halfway into the range, whichever is less.
    target = lower + min(0.1, (upper - lower) / 2)

    Logger.warning([
      @log_prefix,
      "Not enough power: Minimum is ",
      format_kw(lower * demand),
      ", pushing to ",
      format_kw(target * demand),
      "."
    ])

    target
  end

  defp push_into_range(ideal, lower, upper, demand) when ideal > upper do
    # Push 10% below upper, or halfway into the range, whichever is less.
    target = upper - min(0.1, (upper - lower) / 2)

    Logger.warning([
      @log_prefix,
      "Too much power: Maximum is ",
      format_kw(upper * demand),
      ", pushing to ",
      format_kw(target * demand),
      "."
    ])

    target
  end

  def current_ratio(%DT{demand_kwh: demand}, supply), do: supply / demand

  def set_supplied_kwh(%DT{} = dt, kwh), do: %DT{dt | supplied_kwh: kwh}

  def tick(%DT{} = dt, current_supply) do
    old_ts = dt.timestamp
    new_ts = API.Misc.get_time_stamp()
    old_hour = div(old_ts, 60)
    new_hour = div(new_ts, 60)

    # Refresh demand every tick (memoized, so it's free): objectives and
    # hour changes move it, and reacting a minute late costs energy budget.
    %DT{dt | demand_kwh: API.Power.get_demand_kw()}
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
        supply_per_second: Smoother.new(@seconds_per_minute),
        # The fresh smoother is empty until the next tick; remember the
        # closed minute's rate so projections never see a rate gap.
        recent_rate: average_supply
    }
  end

  @doc """
  Snapshot for display: this hour's budget, progress, and the projected
  end-of-hour ratio at the current supply rate.
  """
  def status(%DT{} = dt) do
    elapsed = hour_elapsed_percent(dt.timestamp)
    remaining_min = 60 - rem(dt.timestamp, 60)

    avg_supply_kw =
      case dt.supply_per_second do
        # Right after a minute rollover the smoother is empty — fall back
        # to the closed minute's rate instead of projecting a rate of zero.
        %Smoother{size: 0} -> dt.recent_rate
        smoother -> Smoother.average(smoother)
      end

    projected_kwh =
      case avg_supply_kw do
        nil -> dt.supplied_kwh
        kw -> dt.supplied_kwh + kw * remaining_min / 60.0
      end

    %{
      demand_kw: dt.demand_kwh,
      supplied_kwh: dt.supplied_kwh,
      hour_elapsed: elapsed,
      supply_kw: avg_supply_kw,
      projected_ratio: safe_ratio(projected_kwh, dt.demand_kwh),
      band: {@standard_targets.min, @standard_targets.max}
    }
  end

  defp safe_ratio(_num, demand) when demand <= 0, do: nil
  defp safe_ratio(num, demand), do: num / demand

  defp tick_hour(%DT{} = dt, same, same), do: dt

  defp tick_hour(%DT{} = dt, _, _) do
    %DT{dt | supplied_kwh: 0}
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

  defp format_kw(kw) do
    mw = Float.round(kw / 1000, 1)
    "#{mw} MW"
  end
end
