defmodule AutoNuke.Operator.VacuumTank do
  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.ControlAxis
  alias AutoNuke.API

  defmodule State do
    @enforce_keys [:pump_axis, :crv_axis]
    defstruct(
      mode: :pump,
      switching: true,
      pump_axis: nil,
      crv_axis: nil,
      last_vacuum: nil,
      distress_count: 0
    )
  end

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  @retention_tank API.Vessels.retention_tank()
  @omsi API.Valves.omsi()
  @smsi API.Valves.smsi()
  @crv API.Valves.crv()

  # Apparently it doesn't take much, and this speeds things up.
  @crv_open_percent 10

  # In pump mode, we try to keep the retention tank half full:
  @target_fill_ratio 0.5
  # In CRV mode, we try to keep vacuum at 99.8% (as opposed to 99.9%):
  @target_vacuum_level 0.998
  # Apply a deadband of 0.7 to reduce MSI oscillations.
  # So a 50% MSI setting will need to push above 50.7% to go to 51%,
  # or below 49.3% to drop to 49%.
  @msi_deadband 0.7

  # If running in pump mode and steam climbs past this (kg/min), switch to CRV mode.
  @steam_high_mark 130
  # If running in CRV mode and steam drops below this (kg/min), switch to pump mode.
  @steam_low_mark 110

  # If we're in CRV mode, below 95% vacuum, and we still can't improve vacuum
  # for 10 ticks in a row, then we go permanently to pump mode.
  @distress_vacuum 0.95
  @max_distress_count 10

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    msi = get_msi()

    pump_axis =
      ControlAxis.new(
        kp: 1,
        ki: 0.1,
        kd: 0.2,
        deadzone: 0.005,
        to_value_fn: &axis_to_msi/2,
        to_value_state: msi,
        offset: msi |> msi_to_axis(),
        initial_value: msi
      )

    crv_axis =
      ControlAxis.new(
        kp: 10,
        ki: 1,
        deadzone: 0.0005,
        to_value_fn: &axis_to_msi/2,
        to_value_state: msi,
        offset: msi |> msi_to_axis(),
        initial_value: msi
      )

    state = %State{pump_axis: pump_axis, crv_axis: crv_axis}

    PubSub.subscribe(self(), :ticker)
    filled = API.Vessels.get_fill_percent(@retention_tank) |> Float.round(1)
    Logger.info(@log_prefix <> "Started with fill level of #{filled}%.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state =
      state
      |> maybe_change_mode()
      |> check_distress()
      |> wait_for_switch()

    {axis, target, current} = get_control_metrics(state)

    case ControlAxis.step(axis, target, current) do
      {:changed, axis, new, old} ->
        change_msi(old, new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis ->
      case state.mode do
        :pump -> {:noreply, %State{state | pump_axis: axis}}
        :crv -> {:noreply, %State{state | crv_axis: axis}}
      end
    end)
  end

  defp maybe_change_mode(%State{distress_count: n} = state) when n > @max_distress_count do
    case state.mode do
      :crv -> %State{state | mode: :pump, switching: true}
      :pump -> state
    end
  end

  defp maybe_change_mode(%State{mode: :pump} = state) do
    if API.SteamGen.get_total_outlet() > @steam_high_mark do
      get_msi() |> change_msi(state.crv_axis.last_value)
      %State{state | mode: :crv, switching: true}
    else
      state
    end
  end

  defp maybe_change_mode(%State{mode: :crv} = state) do
    if API.SteamGen.get_total_outlet() < @steam_low_mark do
      get_msi() |> change_msi(state.pump_axis.last_value)
      %State{state | mode: :pump, switching: true}
    else
      state
    end
  end

  defp check_distress(%State{mode: :crv, switching: false} = state) do
    vacuum = API.VacuumPump.get_vacuum_level()
    ticks = state.distress_count

    ticks =
      cond do
        vacuum > @distress_vacuum -> 0
        vacuum > state.last_vacuum -> max(ticks - 1, 0)
        vacuum == state.last_vacuum -> ticks
        true -> ticks + 1
      end

    %State{state | last_vacuum: vacuum, distress_count: ticks}
  end

  defp check_distress(%State{} = state), do: state

  defp wait_for_switch(%State{switching: false} = state), do: state

  defp wait_for_switch(%State{mode: :pump, switching: true} = state) do
    cond do
      get_crv_ordered() > 0 ->
        if state.distress_count > @max_distress_count do
          Logger.error(@log_prefix <> "Unable to maintain vacuum using CRV!")
          Logger.warning(@log_prefix <> "Closing CRV to run vacuum pump ...")
          API.VacuumPump.set_mode(:startup)
        else
          Logger.notice(@log_prefix <> "Steam is low: Closing CRV to run vacuum pump ...")
        end

        set_crv(0)
        state

      get_crv_actual() > 0 ->
        state

      !API.VacuumPump.get_active?() ->
        Logger.notice(@log_prefix <> "CRV closed, starting vacuum pump ...")
        API.VacuumPump.start()
        state

      API.VacuumPump.get_vacuum_level() < 0.99 ->
        state

      true ->
        Logger.notice(@log_prefix <> "Vacuum established, now in pump mode.")
        API.VacuumPump.set_mode(:operational)
        %State{state | switching: false}
    end
  end

  defp wait_for_switch(%State{mode: :crv, switching: true} = state) do
    cond do
      API.VacuumPump.get_active?() ->
        Logger.notice(@log_prefix <> "Steam is high: Disabling pump and switching to CRV...")
        API.VacuumPump.stop()
        state

      get_crv_ordered() < @crv_open_percent ->
        Logger.notice(@log_prefix <> "Vacuum pump offline, opening CRV ...")
        set_crv(@crv_open_percent)
        state

      get_crv_actual() < @crv_open_percent ->
        state

      true ->
        Logger.notice(@log_prefix <> "CRV fully opened, now in CRV mode.")
        %State{state | switching: false}
    end
  end

  defp get_control_metrics(%State{mode: :pump, pump_axis: axis}),
    do: {axis, @target_fill_ratio, get_fill_ratio()}

  defp get_control_metrics(%State{mode: :crv, crv_axis: axis}),
    do: {axis, @target_vacuum_level, API.VacuumPump.get_vacuum_level()}

  defp change_msi(old, new) do
    Logger.info(@log_prefix <> "Changing xMSI from #{old} to #{new}.")
    API.Valves.set_open_percent(@omsi, new)
    API.Valves.set_open_percent(@smsi, new)
  end

  defp get_fill_ratio, do: API.Vessels.get_fill_ratio(@retention_tank)

  defp get_omsi, do: API.Valves.get_open_percent(@omsi)
  defp get_smsi, do: API.Valves.get_open_percent(@smsi)
  defp get_msi, do: round(get_omsi() + get_smsi()) |> div(2)

  defp set_crv(value) when is_integer(value), do: API.Valves.set_open_percent(@crv, value)

  defp get_crv_ordered, do: API.Valves.get_ordered_open_percent(@crv)
  defp get_crv_actual, do: API.Valves.get_open_percent(@crv)

  defp msi_to_axis(msi), do: (msi - 50) / 50.0

  defp axis_to_msi(output, old_msi) do
    # Map -1.0 to 0% and +1.0 to 100%.
    new_msi = 50 + output * 50

    # Apply a deadband around the prior value.
    upper = old_msi + @msi_deadband
    lower = old_msi - @msi_deadband

    if new_msi >= upper || new_msi <= lower do
      round(new_msi)
    else
      old_msi
    end
    |> then(fn value ->
      {:ok, value, value}
    end)
  end
end
