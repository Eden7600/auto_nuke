defmodule AutoNuke.Tui.LogBuffer do
  @moduledoc """
  A ring buffer of recent log lines for display inside the TUI.

  `attach/0` registers an Erlang `:logger` handler that formats each event
  (info and up) into a single line and appends it to an ETS-backed buffer;
  `tail/1` reads the newest lines. Reading is local and cheap, so the
  dashboard just pulls on every data refresh.
  """

  @table :auto_nuke_tui_log
  @max_lines 300
  @handler_id :tui_log_buffer

  # -- Public API -------------------------------------------------------------

  @doc "Install the handler (idempotent). Call once at TUI startup."
  def attach do
    ensure_table()

    :logger.add_handler(@handler_id, __MODULE__, %{
      level: :info,
      config: %{}
    })
    |> case do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  def detach do
    :logger.remove_handler(@handler_id)
    :ok
  end

  @doc "The newest `n` lines, oldest first."
  def tail(n) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        total = counter()

        max(total - n, 0)..(total - 1)//1
        |> Enum.flat_map(fn i ->
          case :ets.lookup(@table, i) do
            [{^i, line}] -> [line]
            [] -> []
          end
        end)
    end
  end

  # -- :logger handler callbacks ----------------------------------------------

  def log(%{level: level, msg: msg, meta: meta}, _config) do
    line = format_line(level, msg, meta)
    append(line)
  rescue
    # A logging handler must never take the app down.
    _ -> :ok
  end

  defp format_line(level, msg, meta) do
    time =
      case meta[:time] do
        t when is_integer(t) ->
          t
          |> System.convert_time_unit(:microsecond, :second)
          |> DateTime.from_unix!()
          |> Calendar.strftime("%H:%M:%S")

        _ ->
          ""
      end

    "#{time} [#{level}] #{format_msg(msg)}"
  end

  defp format_msg({:string, chardata}), do: IO.chardata_to_string(chardata)

  defp format_msg({:report, report}) when is_map(report) or is_list(report),
    do: inspect(Map.new(report))

  defp format_msg({format, args}), do: :io_lib.format(format, args) |> IO.chardata_to_string()

  # -- Ring storage -----------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # Owned by an idle process so it survives whoever attaches.
        holder =
          spawn(fn ->
            :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
            :ets.insert(@table, {:count, 0})

            receive do
              :stop -> :ok
            end
          end)

        # Wait for creation before returning.
        wait_for_table(holder, 50)

      _ ->
        :ok
    end
  end

  defp wait_for_table(_holder, 0), do: :ok

  defp wait_for_table(holder, tries) do
    case :ets.whereis(@table) do
      :undefined ->
        Process.sleep(10)
        wait_for_table(holder, tries - 1)

      _ ->
        :ok
    end
  end

  defp counter do
    case :ets.lookup(@table, :count) do
      [{:count, n}] -> n
      [] -> 0
    end
  end

  defp append(line) do
    index = :ets.update_counter(@table, :count, 1) - 1
    :ets.insert(@table, {index, line})
    # Trim the entry that fell out of the window.
    :ets.delete(@table, index - @max_lines)
    :ok
  end
end
