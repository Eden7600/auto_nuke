defmodule AutoNuke.TaskUI.Refill do
  alias AutoNuke.TaskUI, as: UI

  def refill(opts) do
    {vessel, opts} = Keyword.pop!(opts, :vessel)
    {pump, opts} = Keyword.pop!(opts, :pump)
    {target, opts} = Keyword.pop!(opts, :target_level)

    unless Enum.empty?(opts) do
      raise "Unknown options: #{inspect(opts)}"
    end

    try do
      UI.Pumps.start(pump)
      UI.Vessels.fill_wait(vessel, gauge_level: target)
    after
      UI.Pumps.stop(pump)
    end
  end
end
