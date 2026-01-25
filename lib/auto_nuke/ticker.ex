defmodule AutoNuke.Ticker do
  use GenServer
  require Logger

  @log_prefix "[#{inspect(__MODULE__)}] "
  @loop_every 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    ts = get_timestamp()
    Logger.info(@log_prefix <> "Started with timestamp #{ts}.")
    {:ok, get_timestamp(), {:continue, :loop}}
  end

  @impl true
  def handle_info(:loop, old_ts) do
    case get_timestamp() do
      ^old_ts ->
        {:noreply, old_ts, {:continue, :loop}}

      new_ts ->
        Logger.debug(@log_prefix <> "Ticked #{old_ts} -> #{new_ts}.")
        PubSub.publish(:ticker, {:tick, new_ts})
        {:noreply, new_ts, {:continue, :loop}}
    end
  end

  @impl true
  def handle_continue(:loop, state) do
    Process.send_after(self(), :loop, @loop_every)
    {:noreply, state}
  end

  defp get_timestamp, do: AutoNuke.API.get_integer("TIME_STAMP")
end
