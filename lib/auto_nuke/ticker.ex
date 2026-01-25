defmodule AutoNuke.Ticker do
  use GenServer
  require Logger

  @log_prefix "[#{inspect(__MODULE__)}] "
  @tick_every 200
  @pause_wait 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    schedule_next()
    Logger.info(@log_prefix <> "Started ticking.")
    {:ok, 0}
  end

  @impl true
  def handle_info(:tick, counter) do
    PubSub.publish(:ticker, {:tick, counter})
    schedule_next()
    {:noreply, counter + 1}
  end

  @impl true
  def handle_info(:paused, counter) do
    schedule_next()
    {:noreply, counter}
  end

  defp get_sim_speed, do: AutoNuke.API.get_integer("GAME_SIM_SPEED")

  defp schedule_next do
    {lag, speed} = :timer.tc(&get_sim_speed/0, :millisecond)

    if speed == 0 do
      Process.send_after(self(), :paused, @pause_wait)
    else
      interval =
        @tick_every
        |> div(speed)
        |> Kernel.-(lag)
        |> max(1)

      Process.send_after(self(), :tick, interval)
    end
  end
end
