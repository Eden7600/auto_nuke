defmodule AutoNuke.Operator.VacuumTank do
  use GenServer
  require Logger

  alias AutoNuke.ControlAxis

  @log_prefix "[#{inspect(__MODULE__)}] "

  @tank_size 40000.0
  @target_percent 0.5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    msi = get_msi()

    axis =
      ControlAxis.new(
        kp: 1,
        ki: 0.1,
        deadzone: 0.01,
        to_value_fn: &axis_to_msi/1,
        offset: msi |> msi_to_axis(),
        initial_value: msi
      )

    PubSub.subscribe(self(), :ticker)

    fill_level = get_fill_percent() |> Float.round(2)
    Logger.info(@log_prefix <> "Started with fill level of #{fill_level * 100}%.")

    {:ok, axis}
  end

  @impl true
  def handle_info({:tick, _}, axis) do
    case ControlAxis.step(axis, @target_percent, get_fill_percent()) do
      {:changed, axis, new, old} ->
        change_msi(old, new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis -> {:noreply, axis} end)
  end

  defp change_msi({old_omsi, old_smsi}, {new_omsi, new_smsi}) do
    change_xmsi("OMSI", old_omsi, new_omsi, &set_omsi/1)
    change_xmsi("SMSI", old_smsi, new_smsi, &set_smsi/1)
  end

  defp change_xmsi(name, old, new, set_fn) do
    if old != new do
      Logger.info(@log_prefix <> "Changing #{name} from #{old} to #{new}.")
      set_fn.(new)
    end
  end

  defp get_fill_percent() do
    AutoNuke.API.get_float("VACUUM_RETENTION_TANK_VOLUME") / @tank_size
  end

  @omsi "STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE"
  @smsi "STEAM_EJECTOR_STARTUP_MOTIVE_VALVE"

  defp get_omsi, do: AutoNuke.API.get_integer(@omsi <> "_ORDERED")
  defp get_smsi, do: AutoNuke.API.get_integer(@smsi <> "_ORDERED")
  defp get_msi, do: {get_omsi(), get_smsi()}

  defp set_omsi(value) when is_integer(value), do: AutoNuke.API.put(@omsi, value)
  defp set_smsi(value) when is_integer(value), do: AutoNuke.API.put(@smsi, value)

  defp msi_to_axis({omsi, smsi}) do
    (omsi + smsi - 100) / 100.0
  end

  defp axis_to_msi(output) do
    value = 100 + round(output * 100)
    omsi = min(value, 100)
    smsi = max(value - 100, 0)
    {omsi, smsi}
  end
end
