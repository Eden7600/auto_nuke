defmodule AutoNuke.Ticker do
  use GenServer
  require Logger

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] "

  # Track time in 200ms increments:
  @loop_ms 200
  # If paused, wait 50ms to check if unpaused:
  @pause_wait 50
  # If ping fails, wait this long before retrying.
  @ping_wait 5000

  # Net result:
  #  - Five ticks per in-game second.
  #  - Eight in-game seconds per in-game minute.
  def ticks_per_second, do: 5
  def seconds_per_minute, do: 8

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    ping_wait()
    schedule_next()
    Logger.info(@log_prefix <> "Started ticking.")
    {:ok, 0}
  end

  @impl true
  def handle_info(:tick, counter) do
    Memoize.invalidate(API)
    PubSub.publish(:ticker, {:tick, counter})
    schedule_next()
    {:noreply, counter + 1}
  end

  @impl true
  def handle_info(:paused, state) do
    schedule_next()
    {:noreply, state}
  end

  defp ping_wait do
    case API.Web.ping() do
      true ->
        :ok

      false ->
        Logger.error(@log_prefix <> "API unreachable, retrying in #{@ping_wait} ms.")
        Process.sleep(@ping_wait)
        ping_wait()
    end
  end

  defp get_sim_speed do
    Memoize.invalidate(API, :get_integer, ["GAME_SIM_SPEED"])
    API.get_integer("GAME_SIM_SPEED")
  end

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
