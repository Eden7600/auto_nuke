defmodule AutoNuke.Tasks.Refill do
  alias AutoNuke.TaskUI, as: UI

  def refill(opts) do
    {:ok, _} = Application.ensure_all_started([:req])

    {pump_name, opts} = Keyword.pop!(opts, :pump_name)
    {tank_desc, opts} = Keyword.pop!(opts, :tank_description)
    {pump_get, opts} = Keyword.pop!(opts, :pump_get_active)
    {pump_set, opts} = Keyword.pop!(opts, :pump_set_enabled)
    {tank_get, opts} = Keyword.pop!(opts, :tank_get_level)
    {target, opts} = Keyword.pop!(opts, :target_level)
    {pre_check, opts} = Keyword.pop(opts, :pre_check, fn -> :noop end)

    unless Enum.empty?(opts) do
      raise "Unknown options: #{inspect(opts)}"
    end

    pre_check.()

    try do
      UI.set_wait_unless(
        pump_name,
        "ON",
        fn -> tank_get.() >= target end,
        fn -> pump_get.() end,
        fn -> pump_set.(true) end
      )

      UI.progress_loop(
        label: tank_desc,
        fetch: tank_get,
        max: target
      )
    after
      UI.set_wait(
        pump_name,
        "OFF",
        fn -> !pump_get.() end,
        fn -> pump_set.(false) end
      )
    end
  end
end
