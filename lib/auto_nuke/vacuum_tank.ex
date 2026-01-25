defmodule AutoNuke.VacuumTank do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:pid, :fill_level, :omsi, :smsi]
    defstruct(@enforce_keys)
  end

  @log_prefix "[#{inspect(__MODULE__)}] "
  @loop_every 100

  @tank_size 40000.0
  @target_percent 0.5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    pid = PIDControl.new(kp: 30, kd: 1, ki: 0.1)

    state = %State{
      pid: pid,
      fill_level: get_fill_percent(),
      smsi: get_smsi(),
      omsi: get_omsi()
    }

    Logger.info(@log_prefix <> "Started with fill level of #{state.fill_level * 100}%.")
    {:ok, state, {:continue, :loop}}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      get_fill_percent()
      |> update_fill_level(state)

    {:noreply, state, {:continue, :loop}}
  end

  @impl true
  def handle_continue(:loop, state) do
    Process.send_after(self(), :loop, @loop_every)
    {:noreply, state}
  end

  defp update_fill_level(level, %State{fill_level: level} = state) do
    # Nothing changed.
    state
  end

  defp update_fill_level(new_level, %State{} = state) do
    pid = state.pid |> PIDControl.step(@target_percent, new_level)

    state = %State{state | pid: pid, fill_level: new_level}

    if pid.output < 0 do
      state
      |> update_smsi(0)
      |> update_omsi(100 + round(100 * pid.output))
    else
      state
      |> update_omsi(100)
      |> update_smsi(round(100 * pid.output))
    end
  end

  defp update_omsi(%State{omsi: same} = state, same), do: state

  defp update_omsi(%State{omsi: old} = state, new) do
    Logger.info(@log_prefix <> "Changing OMSI from #{old} to #{new}.")
    set_omsi(new)
    %State{state | omsi: new}
  end

  defp update_smsi(%State{smsi: same} = state, same), do: state

  defp update_smsi(%State{smsi: old} = state, new) do
    Logger.info(@log_prefix <> "Changing SMSI from #{old} to #{new}.")
    set_smsi(new)
    %State{state | smsi: new}
  end

  defp get_fill_percent() do
    AutoNuke.API.get_float("VACUUM_RETENTION_TANK_VOLUME") / @tank_size
  end

  @omsi "STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE"
  @smsi "STEAM_EJECTOR_STARTUP_MOTIVE_VALVE"

  defp get_omsi(), do: AutoNuke.API.get_integer(@omsi <> "_ORDERED")
  defp get_smsi(), do: AutoNuke.API.get_integer(@smsi <> "_ORDERED")
  defp get_bypass(), do: AutoNuke.API.get_integer("STEAM_TURBINE_2_BYPASS_ACTUAL")

  defp set_omsi(value) when is_integer(value), do: AutoNuke.API.put(@omsi, value)
  defp set_smsi(value) when is_integer(value), do: AutoNuke.API.put(@smsi, value)
end
