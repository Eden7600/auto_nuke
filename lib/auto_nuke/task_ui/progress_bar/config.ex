defmodule AutoNuke.TaskUI.ProgressBar.Config do
  @enforce_keys [:left, :right]
  defstruct(
    left: nil,
    right: nil,
    suffix_style: :portion,
    decimals: 0,
    units: nil
  )

  alias __MODULE__

  def percent(decimals \\ 1, right \\ 100) do
    %Config{
      left: 0,
      right: right,
      units: "%",
      decimals: decimals
    }
  end

  def reverse_percent(decimals \\ 1),
    do: %Config{percent(decimals) | left: 100, right: 0, suffix_style: :target}

  def target(left, right, units \\ "", decimals \\ 0) do
    %Config{
      left: left,
      right: right,
      units: units,
      decimals: decimals,
      suffix_style: :target
    }
  end
end
