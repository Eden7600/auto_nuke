defmodule AutoNuke.Ticker do
  use GenServer
  require Logger

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Track time in 200ms increments:
  @loop_ms 200
  # Emit ticks every 5 loops (1 second):
  @tick_loops 5
  # If paused, wait 50ms to check if unpaused:
  @pause_wait 50

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    schedule_next()
    Logger.info(@log_prefix <> "Started ticking.")
    {:ok, {0, @tick_loops}}
  end

  @impl true
  def handle_info(:tick, {counter, 0}) do
    PubSub.publish(:ticker, {:tick, counter})
    schedule_next()
    {:noreply, {counter + 1, @tick_loops}}
  end

  @impl true
  def handle_info(:tick, {counter, loops}) when loops in 1..@tick_loops do
    schedule_next()
    {:noreply, {counter, loops - 1}}
  end

  @impl true
  def handle_info(:paused, state) do
    schedule_next()
    {:noreply, state}
  end

  defp get_sim_speed, do: AutoNuke.API.get_integer("GAME_SIM_SPEED")

  defp schedule_next do
    {lag, speed} = :timer.tc(&get_sim_speed/0, :millisecond)

    if speed == 0 do
      Process.send_after(self(), :paused, @pause_wait)
    else
      interval =
        @loop_ms
        |> div(speed)
        |> Kernel.-(lag)
        |> max(1)

      Process.send_after(self(), :tick, interval)
    end
  end
end
