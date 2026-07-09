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
  defstruct(@enforce_keys)

  alias __MODULE__

  def wait(opts) do
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

    try do
      Task.async(fn ->
        PubSub.subscribe(self(), :ticker)

        %ProgressBar{
          config: config,
          current_fn: current_fn,
          done_fn: done_fn,
          prefix: prefix,
          suffix_width: suffix_width,
          target: target
        }
        |> loop()
      end)
      |> Task.await(:infinity)
    after
      IO.puts("")
    end
  end

  defp loop(%ProgressBar{} = bar) do
    receive do
      {:tick, _} -> :ok
    end

    value = bar.current_fn.()

    case bar.done_fn.(value) do
      :abort ->
        IO.write(:stdio, render(bar, value))

      false ->
        IO.write(:stdio, render(bar, value))
        loop(bar)

      true ->
        prefix = bar.prefix |> String.replace(UI.emoji(:spin), UI.emoji(:checkmark))
        bar = %ProgressBar{bar | prefix: prefix}
        IO.write(:stdio, render(bar, value))
    end
  end

  defp render(%ProgressBar{} = bar, value) do
    suffix =
      format_number(value, bar.config.decimals)
      |> render_suffix(bar.target, bar.config.suffix_style)
      |> String.pad_leading(bar.suffix_width)

    bar_width = UI.width() - String.length(bar.prefix) - String.length(suffix) - 3
    percent = percent_of_range(value, bar.config.left, bar.config.right)
    ticks = round(@bar_ticks * bar_width * percent)

    full_bars = div(ticks, @bar_ticks) |> min(bar_width)
    partial_bar = if full_bars >= bar_width, do: -1, else: rem(ticks, @bar_ticks)
    empties = (bar_width - full_bars - 1) |> max(0)

    [
      "\r",
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
