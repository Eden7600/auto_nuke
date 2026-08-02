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

  # Init never blocks: the TUI must come up with the game offline. While
  # disconnected we ping on an interval; once connected, ticks flow, and a
  # failed tick drops back to the ping loop.
  @impl true
  def init(nil) do
    API.Web.set_config(:fast)
    send(self(), :connect)
    {:ok, :disconnected}
  end

  @impl true
  def handle_info(:connect, _state) do
    case API.Web.ping() do
      :ok ->
        Logger.info(@log_prefix <> "Connected, started ticking.")

        case try_schedule() do
          :ok -> {:noreply, 0}
          :error -> {:noreply, retry_connect()}
        end

      {:error, reason} ->
        Logger.error(@log_prefix <> "API not ready: #{reason}")
        {:noreply, retry_connect()}
    end
  end

  @impl true
  def handle_info(:tick, :disconnected), do: {:noreply, :disconnected}

  @impl true
  def handle_info(:tick, counter) do
    Memoize.invalidate(API)
    PubSub.publish(:ticker, {:tick, counter})

    case try_schedule() do
      :ok -> {:noreply, counter + 1}
      :error -> {:noreply, retry_connect()}
    end
  end

  @impl true
  def handle_info(:paused, :disconnected), do: {:noreply, :disconnected}

  @impl true
  def handle_info(:paused, state) do
    case try_schedule() do
      :ok -> {:noreply, state}
      :error -> {:noreply, retry_connect()}
    end
  end

  defp retry_connect do
    Process.send_after(self(), :connect, @ping_wait)
    :disconnected
  end

  defp try_schedule do
    schedule_next()
    :ok
  rescue
    error ->
      Logger.error(@log_prefix <> "Lost the game connection: #{Exception.message(error)}")
      :error
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
