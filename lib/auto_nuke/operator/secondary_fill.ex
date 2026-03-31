defmodule AutoNuke.Operator.SecondaryFill do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:loop, :speed, :capacity]
    defstruct(@enforce_keys)
  end

  @tank_size 60000.0

  # Target between 49% and 51% fill.
  @fill_target_min 0.49
  @fill_target_max 0.51
  # Outside this range, adjust pump speed by 1.
  @fill_target_pump_adjust 1
  # Keep fill between 30% and 70%.
  @fill_limit_min 0.30
  @fill_limit_max 0.70
  # Outside this range, we have a 10% scaling range.
  # This will scale pumps up to 100% at 20% fill or lower,
  # and down to 0% at 80% fill or higher.
  @fill_limit_span 0.10

  defp process_name(loop), do: __MODULE__ |> Module.concat("L#{loop}")

  def child_spec(opts) do
    loop = Keyword.fetch!(opts, :loop)

    %{
      id: process_name(loop),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    {loop, opts} = Keyword.pop!(opts, :loop)
    opts = Keyword.put_new(opts, :name, process_name(loop))
    GenServer.start_link(__MODULE__, loop, opts)
  end

  @impl true
  def init(loop) when loop in 1..3 do
    if is_installed?(loop) do
      do_init(loop)
    else
      Logger.info(log_prefix(loop) <> "Steam generator is not installed.")
      {:ok, nil}
    end
  end

  defp do_init(loop) do
    capacity = get_capacity(loop)
    speed = get_speed(loop)
    fill_level = (get_current_fill_percent(loop) * 100) |> Float.round(2)

    state = %State{
      loop: loop,
      speed: speed,
      capacity: capacity
    }

    PubSub.subscribe(self(), :ticker)

    Logger.info(
      log_prefix(loop) <>
        "Started with pump capacity #{capacity} and fill level of #{fill_level}%."
    )

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{loop: loop, speed: old_speed} = state) do
    new_speed = calculate_speed(loop, state.capacity)

    if new_speed != old_speed do
      Logger.info(log_prefix(loop) <> "Changing speed from #{old_speed} to #{new_speed}.")
      set_speed(loop, new_speed)
      {:noreply, %State{state | speed: new_speed}}
    else
      {:noreply, state}
    end
  end

  defp calculate_speed(loop, capacity) do
    ideal = get_steam_outlet(loop) / capacity * 100
    fill_level = get_current_fill_percent(loop)

    cond do
      fill_level < @fill_limit_min ->
        error = @fill_limit_min - fill_level
        percent = (error / @fill_limit_span) |> min(1.0)
        adjust = (100 - ideal) * percent
        ideal + max(adjust, @fill_target_pump_adjust)

      fill_level > @fill_limit_max ->
        error = fill_level - @fill_limit_max
        percent = (error / @fill_limit_span) |> min(1.0)
        adjust = ideal * percent
        ideal - max(adjust, @fill_target_pump_adjust)

      fill_level < @fill_target_min ->
        ideal + @fill_target_pump_adjust

      fill_level > @fill_target_max ->
        ideal - @fill_target_pump_adjust

      true ->
        ideal
    end
    |> round()
    |> max(0)
    |> min(100)
  end

  defp get_current_fill_percent(loop) do
    AutoNuke.API.get_float("COOLANT_SEC_#{loop - 1}_LIQUID_VOLUME") / @tank_size
  end

  defp is_installed?(loop) do
    AutoNuke.API.get_integer("STEAM_GEN_#{loop - 1}_STATUS") == 2
  end

  defp get_capacity(loop) do
    AutoNuke.API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_CAPACITY")
  end

  defp get_steam_outlet(loop) do
    AutoNuke.API.get_float("STEAM_GEN_#{loop - 1}_OUTLET")
  end

  defp get_speed(loop) do
    AutoNuke.API.get_integer("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED")
  end

  defp set_speed(loop, value) do
    AutoNuke.API.put("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_ORDERED_SPEED", value)
  end

  def axis_to_speed(output), do: round(50 + output * 50)
  def speed_to_axis(speed), do: (speed - 50) / 50

  defp log_prefix(loop), do: "[#{inspect(__MODULE__)}.L#{loop}] "
end
