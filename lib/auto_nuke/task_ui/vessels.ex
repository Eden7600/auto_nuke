defmodule AutoNuke.TaskUI.Vessels do
  alias AutoNuke.API.Vessels, as: API_V
  alias AutoNuke.API.Vessels.Vessel
  alias AutoNuke.TaskUI, as: UI

  def fill_wait(%Vessel{} = vessel, opts) do
    {percent, opts} = Keyword.pop(opts, :percent)
    {gauge_level, opts} = Keyword.pop(opts, :gauge_level)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    cond do
      is_nil(percent) == is_nil(gauge_level) ->
        raise "Must specify exactly one of `gauge_level` or `percent`"

      !is_nil(percent) ->
        do_fill_wait(vessel, percent_to_gauge_level(vessel, percent))

      !is_nil(gauge_level) ->
        do_fill_wait(vessel, gauge_level)
    end
  end

  defp do_fill_wait(%Vessel{} = vessel, target) do
    UI.ProgressBar.wait(
      config: fill_config(vessel, target),
      label: vessel.short_name,
      current_fn: fn -> API_V.get_fill_gauge(vessel) end,
      done_fn: &(&1 >= target)
    )
  end

  defp fill_config(%Vessel{gauge_units: units}, target) do
    %UI.ProgressBar.Config{
      left: 0,
      right: target,
      suffix_style: :portion,
      decimals: decimals_for_units(units),
      units: if(units =~ ~r/^[A-Za-z]/, do: " #{units}", else: units)
    }
  end

  def gauge_capacity(%Vessel{capacity: c, gauge_units: u}), do: c / gauge_factor(u)

  defp percent_to_gauge_level(%Vessel{gauge_units: "%"}, p), do: p

  defp percent_to_gauge_level(%Vessel{capacity: c, gauge_units: u}, p) do
    (c * p / 100)
    |> Kernel./(gauge_factor(u))
    |> maybe_round()
  end

  defp maybe_round(n) do
    rounded = round(n)

    if abs(n - rounded) < 0.0001 do
      rounded
    else
      n
    end
  end

  defp decimals_for_units("%"), do: 1
  defp decimals_for_units("kL"), do: 1
  defp decimals_for_units(_), do: 1

  defp gauge_factor("hL"), do: 100
  defp gauge_factor("kL"), do: 1000
  # This one is weird.  It seems that 120 kL = 2500 m³ (x48) in the core vessel??
  # That's distinct from the conversion between PCST tank and core vessel,
  # which seems to be 1 kL = 20 m³ instead.
  defp gauge_factor("m³"), do: 48
end
