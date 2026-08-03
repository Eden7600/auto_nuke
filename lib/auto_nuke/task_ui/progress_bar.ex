defmodule AutoNuke.TaskUI.ProgressBar do
  alias AutoNuke.TaskUI, as: UI

  @full_bar "\u2588"
  @empty_bar "\u2e31"
  @partial_bars [
    @empty_bar,
    "\u258F",
    "\u258E",
    "\u258D",
    "\u258C",
    "\u258B",
    "\u258A",
    "\u2589",
    ""
  ]
  @bar_ticks 8

  @enforce_keys [:config, :current_fn, :done_fn, :prefix, :suffix_width, :target]
  defstruct(@enforce_keys ++ [width: nil])

  alias __MODULE__

  @doc """
  Run several bars at once, side by side on one line.

  Each spec takes the same `:config`, `:label` and `:current_fn` as
  `wait/1`. `until` receives the list of sampled values (in spec order)
  and returns `true` when the whole group is finished, or `:abort` to
  give up. The available width is split evenly between the bars.
  """
  def wait_many(specs, until) when is_list(specs) and is_function(until, 1) do
    width = div(UI.width(), length(specs)) - 1
    bars = Enum.map(specs, &(&1 |> build() |> Map.put(:width, width)))

    try do
      Task.async(fn ->
        PubSub.subscribe(self(), :ticker)
        multi_loop(bars, until)
      end)
      |> Task.await(:infinity)
    after
      IO.puts("")
    end
  end

  defp multi_loop(bars, until) do
    receive do
      {:tick, _} -> :ok
    end

    values = Enum.map(bars, & &1.current_fn.())

    case until.(values) do
      true ->
        write_multi(bars, values, :checkmark)

      :abort ->
        write_multi(bars, values, :spin)

      false ->
        write_multi(bars, values, :spin)
        multi_loop(bars, until)
    end
  end

  defp write_multi(bars, values, emoji) do
    bars
    |> Enum.zip(values)
    |> Enum.map(fn {%ProgressBar{} = bar, value} ->
      render(%ProgressBar{bar | prefix: swap_emoji(bar.prefix, emoji)}, value)
    end)
    |> Enum.intersperse(" ")
    |> then(&IO.write(:stdio, ["\r" | &1]))
  end

  defp swap_emoji(prefix, :spin), do: prefix
  defp swap_emoji(prefix, emoji), do: String.replace(prefix, UI.emoji(:spin), UI.emoji(emoji))

  def wait(opts) do
    bar = build(opts)

    try do
      Task.async(fn ->
        PubSub.subscribe(self(), :ticker)
        loop(bar)
      end)
      |> Task.await(:infinity)
    after
      IO.puts("")
    end
  end

  defp build(opts) do
    {config, opts} = Keyword.pop!(opts, :config)
    {label, opts} = Keyword.pop(opts, :label)
    {current_fn, opts} = Keyword.pop!(opts, :current_fn)

    {done_fn, opts} =
      Keyword.pop_lazy(opts, :done_fn, fn ->
        case config.right > config.left do
          true -> fn v -> v >= config.right end
          false -> fn v -> v <= config.right end
        end
      end)

    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    prefix =
      case label do
        l when is_binary(l) -> "#{UI.emoji(:spin)}  #{l}"
        nil -> "#{UI.emoji(:spin)} "
      end

    # Note that if `config.right` is an integer, then this won't have any decimals at all.
    target = format_number(config.right, config.decimals) <> (config.units || "")

    suffix_width =
      [
        # Force these to decimals for accurate width calculation.
        (config.left * 1.0)
        |> format_number(config.decimals)
        |> render_suffix(target, config.suffix_style),
        (config.right * 1.0)
        |> format_number(config.decimals)
        |> render_suffix(target, config.suffix_style)
      ]
      |> Enum.map(&String.length/1)
      |> Enum.max()

    %ProgressBar{
      config: config,
      current_fn: current_fn,
      done_fn: done_fn,
      prefix: prefix,
      suffix_width: suffix_width,
      target: target
    }
  end

  defp loop(%ProgressBar{} = bar) do
    receive do
      {:tick, _} -> :ok
    end

    value = bar.current_fn.()

    case bar.done_fn.(value) do
      :abort ->
        IO.write(:stdio, ["\r", render(bar, value)])

      false ->
        IO.write(:stdio, ["\r", render(bar, value)])
        loop(bar)

      true ->
        prefix = bar.prefix |> String.replace(UI.emoji(:spin), UI.emoji(:checkmark))
        bar = %ProgressBar{bar | prefix: prefix}
        IO.write(:stdio, ["\r", render(bar, value)])
    end
  end

  defp render(%ProgressBar{} = bar, value) do
    suffix =
      format_number(value, bar.config.decimals)
      |> render_suffix(bar.target, bar.config.suffix_style)
      |> String.pad_leading(bar.suffix_width)

    width = bar.width || UI.width()
    bar_width = width - String.length(bar.prefix) - String.length(suffix) - 3
    percent = percent_of_range(value, bar.config.left, bar.config.right)
    ticks = round(@bar_ticks * bar_width * percent)

    full_bars = div(ticks, @bar_ticks) |> min(bar_width)
    partial_bar = if full_bars >= bar_width, do: -1, else: rem(ticks, @bar_ticks)
    empties = (bar_width - full_bars - 1) |> max(0)

    [
      bar.prefix,
      " ",
      String.duplicate(@full_bar, max(full_bars, 0)),
      Enum.at(@partial_bars, partial_bar),
      String.duplicate(@empty_bar, max(empties, 0)),
      " ",
      suffix
    ]
  end

  defp percent_of_range(value, left, right) do
    ((value - left) / (right - left))
    |> max(0.0)
    |> min(100.0)
  end

  defp format_number(n, _) when is_integer(n), do: Integer.to_string(n)

  defp format_number(n, d) when is_float(n) and is_integer(d) do
    :erlang.float_to_binary(n, decimals: d)
  end

  defp render_suffix(value, target, :portion), do: "#{value}/#{target}"
  defp render_suffix(value, target, :target), do: "#{value} → #{target}"
end
