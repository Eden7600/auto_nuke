defmodule AutoNuke.TimeTracker do
  use GenServer
  require Logger

  @log_prefix "[#{inspect(__MODULE__)}] "
  @ets :time_tracker

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    PubSub.subscribe(self(), :ticker)

    :ets.new(@ets, [
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.info(@log_prefix <> "Started tracking.")
    {:ok, :start_wait}
  end

  @impl true
  def handle_info({:tick, _}, :start_wait) do
    ts = AutoNuke.API.Misc.get_time_stamp()
    {:noreply, {ts, :sync}}
  end

  @impl true
  def handle_info({:tick, tick}, {old_ts, start_tick}) do
    new_ts = AutoNuke.API.Misc.get_time_stamp()

    cond do
      new_ts > old_ts ->
        {:noreply, set(new_ts, tick, tick)}

      new_ts < old_ts ->
        Logger.error(@log_prefix <> "Time has gone backwards!  Restarting ...")
        {:stop, :normal, nil}

      is_integer(start_tick) ->
        {:noreply, set(old_ts, tick, start_tick)}

      start_tick == :sync ->
        {:noreply, {old_ts, :sync}}
    end
  end

  defp set(timestamp, tick, start) do
    :ets.insert(@ets, {:time, timestamp, tick - start})
    {timestamp, start}
  end

  def get do
    try do
      case :ets.lookup(@ets, :time) do
        [{:time, timestamp, ticks}] ->
          {timestamp, ticks}

        [] ->
          nil
      end
    rescue
      # Happens when the ETS doesn't exist yet.
      ArgumentError -> nil
    end
  end
end
