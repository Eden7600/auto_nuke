defmodule Mix.Tasks.AutoNuke.Refill.Internal do
  @moduledoc "Refills multiple tanks with the Internal Freight Pump"
  @shortdoc "Refills M01/M02/M03"

  use Mix.Task
  alias AutoNuke.API
  alias AutoNuke.TaskUI, as: UI

  @pump API.Pumps.internal_freight()
  @target_percent 99.0

  @all_tanks [
    {API.Valves.valve_m01(), API.Vessels.rinse_tank()},
    {API.Valves.valve_m02(), API.Vessels.primary_cst()},
    {API.Valves.valve_m03(), API.Vessels.core_pool_storage()}
  ]

  def run([]) do
    UI.init()

    tanks_status = get_tanks_status()
    show_tanks_status(tanks_status)
    UI.notice("You can safely open and close valves while this task is running.")

    try do
      UI.Pumps.start(@pump)

      fill_loop(tanks_status)
    after
      UI.Pumps.stop(@pump)
    end
  end

  defp get_tanks_status do
    @all_tanks
    |> Map.new(fn {valve, tank} ->
      is_open = API.Valves.get_opened?(valve)
      is_full = API.Vessels.get_fill_percent(tank) >= @target_percent
      {tank, {is_open, is_full}}
    end)
  end

  defp show_tanks_status(new, old \\ %{}) do
    @all_tanks
    |> Enum.map(fn {valve, tank} ->
      {was_open, was_full} = Map.get(old, tank, {nil, nil})
      {is_open, is_full} = Map.fetch!(new, tank)

      if is_open != was_open, do: UI.set(valve.name, if(is_open, do: "OPEN", else: "CLOSED"))
      if is_full != was_full, do: UI.set(tank.name, if(is_full, do: "FULL", else: "NOT FULL"))

      is_open && !is_full
    end)
    |> then(fn
      [] -> UI.warn("No valves open or all tanks full, can't run pump!")
      _ -> :ok
    end)
  end

  defp fill_loop(tanks_status) do
    label =
      @all_tanks
      |> Enum.filter(fn {_, tank} ->
        {open, full} = Map.fetch!(tanks_status, tank)
        open && !full
      end)
      |> Enum.map(fn {valve, _} -> valve.short_name end)
      |> Enum.join("+")

    active_tanks =
      tanks_status
      |> Enum.filter(fn {_, {open, full}} -> open && !full end)
      |> Enum.map(fn {tank, _} -> tank end)

    unless Enum.empty?(active_tanks) do
      UI.ProgressBar.wait(
        config: UI.ProgressBar.Config.percent(),
        label: label,
        current_fn: fn ->
          active_tanks
          |> Enum.map(&API.Vessels.get_fill_percent/1)
          |> Statistex.average()
        end,
        done_fn: fn percent ->
          if tanks_status != get_tanks_status() do
            :abort
          else
            percent >= @target_percent
          end
        end
      )

      new_tanks_status = get_tanks_status()

      if new_tanks_status != tanks_status do
        show_tanks_status(new_tanks_status, tanks_status)
        fill_loop(new_tanks_status)
      else
        :done
      end
    end
  end
end
