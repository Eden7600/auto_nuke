defmodule AutoNuke.Operator.SteamFlow.TorqueLimiter do
  @enforce_keys [:loop, :last_torque, :bypass_wanted]
  defstruct(
    loop: nil,
    last_torque: nil,
    bypass_wanted: nil,
    bypass_max: 100,
    timer: 0
  )

  require Logger
  alias __MODULE__, as: TL
  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] "

  @minimum_torque 3.0
  @critical_torque 2.5

  # When torque is above minimum, wait at least 10 ticks between each 1% relaxation.
  # At normal speed, this should be 5 seconds.
  @relax_wait 10
  # When torque is below critical, wait only 4 ticks between each 1% backoff.
  # At normal speed, this should be 2 seconds.
  @backoff_wait 4

  def new(loop) when loop in 1..3 do
    %TL{
      loop: loop,
      last_torque: get_torque(loop),
      bypass_wanted: get_actual_bypass(loop)
    }
  end

  def set_bypass(%TL{loop: loop} = limiter, wanted) do
    max = limiter.bypass_max

    if wanted > max do
      Logger.info(@log_prefix <> "Loop #{loop} wants #{wanted}% bypass but limited to #{max}%.")
    end

    new_bypass = min(wanted, max)
    set_ordered_bypass(loop, new_bypass)

    %TL{limiter | bypass_wanted: wanted}
    |> check_torque()
  end

  def check_torque(%TL{} = limiter) do
    torque = get_torque(limiter.loop)

    state =
      cond do
        torque < @critical_torque -> :critical
        torque < @minimum_torque -> :minimum
        true -> :okay
      end

    direction =
      cond do
        torque < limiter.last_torque -> :decreasing
        torque > limiter.last_torque -> :increasing
        true -> :stable
      end

    case {state, direction} do
      {:critical, :decreasing} -> emergency_backoff(limiter, torque)
      {:critical, :stable} -> maybe_backoff(limiter, torque)
      {:critical, :increasing} -> reset_timer(limiter)
      {:minimum, :decreasing} -> hold_current_bypass(limiter, torque)
      {:minimum, _} -> reset_timer(limiter)
      {:okay, :decreasing} -> reset_timer(limiter)
      {:okay, _} -> maybe_relax(limiter, torque)
    end
    |> then(fn %TL{} = limiter ->
      %TL{limiter | last_torque: torque}
    end)
  end

  defp get_torque(loop), do: API.get_float("STEAM_TURBINE_#{loop - 1}_TORQUE") |> Float.floor(2)
  defp get_actual_bypass(loop), do: API.get_integer("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL")

  defp set_ordered_bypass(loop, value),
    do: API.put("STEAM_TURBINE_#{loop - 1}_BYPASS_ORDERED", value)

  defp emergency_backoff(%TL{loop: loop} = limiter, torque) do
    new_max = get_actual_bypass(loop) - 1

    Logger.error(
      @log_prefix <> "Loop #{loop} torque at #{torque}, backing off to #{new_max}% bypass."
    )

    limiter |> set_bypass_max(new_max)
  end

  defp hold_current_bypass(%TL{loop: loop} = limiter, torque) do
    new_max = get_actual_bypass(loop)

    if new_max != limiter.bypass_max do
      Logger.warning(
        @log_prefix <> "Loop #{loop} torque at #{torque}, holding at #{new_max}% bypass."
      )

      limiter |> set_bypass_max(new_max)
    else
      limiter
    end
  end

  defp set_bypass_max(%TL{} = limiter, max) do
    cond do
      max > limiter.bypass_max -> increase_max_bypass(limiter, max)
      max < limiter.bypass_max -> decrease_max_bypass(limiter, max)
      max == limiter.bypass_max -> limiter
    end
    |> reset_timer()
  end

  defp increase_max_bypass(%TL{loop: loop} = limiter, new_max) do
    if limiter.bypass_wanted >= limiter.bypass_max do
      order = min(limiter.bypass_wanted, new_max)
      Logger.debug(@log_prefix <> "Loop #{loop} following bypass increase to #{order}%.")
      set_ordered_bypass(loop, order)
    end

    %TL{limiter | bypass_max: new_max}
  end

  defp decrease_max_bypass(%TL{loop: loop} = limiter, new_max) do
    if limiter.bypass_wanted > new_max do
      Logger.debug(@log_prefix <> "Loop #{loop} backing off to #{new_max}%.")
      set_ordered_bypass(loop, new_max)
    end

    %TL{limiter | bypass_max: new_max}
  end

  defp reset_timer(%TL{} = tl), do: %TL{tl | timer: 0}

  defp maybe_relax(%TL{bypass_max: 100} = lim, _), do: lim
  defp maybe_relax(%TL{timer: t} = lim, _) when t < @relax_wait, do: %TL{lim | timer: t + 1}

  defp maybe_relax(%TL{loop: loop} = limiter, torque) do
    new_max = limiter.bypass_max + 1

    cond do
      new_max == 100 ->
        Logger.info(@log_prefix <> "Loop #{loop} torque at #{torque}, now fully relaxed.")

      limiter.bypass_wanted >= new_max ->
        Logger.info(
          @log_prefix <> "Loop #{loop} torque at #{torque}, relaxing to #{new_max}% bypass."
        )

      true ->
        :silent
    end

    limiter |> set_bypass_max(new_max)
  end

  defp maybe_backoff(%TL{timer: t} = lim, _) when t < @backoff_wait, do: %TL{lim | timer: t + 1}

  defp maybe_backoff(%TL{loop: loop} = limiter, torque) do
    new_max = limiter.bypass_max - 1

    Logger.info(
      @log_prefix <> "Loop #{loop} torque at #{torque}, backing off to #{new_max}% bypass."
    )

    limiter |> set_bypass_max(new_max)
  end
end
