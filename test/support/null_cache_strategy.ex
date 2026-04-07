defmodule AutoNuke.Test.NullCacheStrategy do
  @behaviour Memoize.CacheStrategy
  @ets_tab __MODULE__

  # Caching strategy that aims to completely disable memoization.
  # Each PID uses their own ETS table in order to allow async operation,
  # and each PID-specific table is fully cleared after every read.

  def init(_) do
    :ets.new(@ets_tab, [:public, :set, :named_table, {:read_concurrency, true}])
    []
  end

  def tab(_key) do
    pid = self()

    case :ets.lookup(@ets_tab, pid) do
      [{^pid, table}] ->
        table

      [] ->
        table = make_table(pid)
        :ets.insert(@ets_tab, {pid, table})
        table
    end
  end

  defp make_table(pid) when is_pid(pid) do
    ets_table_name(pid)
    |> :ets.new([:public, :set, :named_table, {:read_concurrency, true}])
  end

  defp ets_table_name(pid) when is_pid(pid) do
    inspect(pid)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.to_atom()
  end

  def cache(_key, _value, _opts), do: nil

  def read(_key, _value, _context) do
    tab(nil) |> :ets.delete_all_objects()
    :ok
  end

  def invalidate, do: nil
  def invalidate(_key), do: nil
  def garbage_collect, do: nil
end
