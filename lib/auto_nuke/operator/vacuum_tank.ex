defmodule AutoNuke.Operator.VacuumTank do
  use GenServer
  require Logger

  alias AutoNuke.ControlAxis
  alias AutoNuke.API

  defmodule State do
    @enforce_keys [:axis]
    defstruct(
      mode: :pump,
      switching: true,
      axis: nil
    )
  end

  @log_prefix "[#{inspect(__MODULE__)}] "

  # In pump mode, we try to keep the retention tank half full:
  @tank_size 40000.0
  @target_fill_percent 0.5
  # In CRV mode, we try to keep vacuum at 99% (as opposed to 99.9%):
  @target_vacuum_level 0.99
  # Vacuum level is a lot more precise than tank fill level,
  # so to keep all the AxisController parameters the same
  # (especially deadzone), we scale up our current and target
  # vacuum level by an order of magnitude.
  @crv_target_factor 10

  # If running in pump mode and steam climbs past this (kg/min), switch to CRV mode.
  @steam_high_mark 110
  # If running in CRV mode and steam drops below this (kg/min), switch to pump mode.
  @steam_low_mark 90

  def tank_size, do: @tank_size

  def start_link(opts \\ []) do
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

    state = %State{axis: axis}

    PubSub.subscribe(self(), :ticker)
    fill_level = get_fill_percent() |> Float.round(2)
    Logger.info(@log_prefix <> "Started with fill level of #{fill_level * 100}%.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state =
      state
      |> maybe_change_mode()
      |> wait_for_switch()

    {target, current} = get_control_metrics(state.mode)

    case ControlAxis.step(state.axis, target, current) do
      {:changed, axis, new, old} ->
        change_msi(old, new)
        axis

      {:unchanged, axis, _old_value} ->
        axis
    end
    |> then(fn axis -> {:noreply, %State{state | axis: axis}} end)
  end

  defp maybe_change_mode(%State{mode: :pump} = state) do
    if get_total_steam() > @steam_high_mark do
      %State{state | mode: :crv, switching: true}
    else
      state
    end
  end

  defp maybe_change_mode(%State{mode: :crv} = state) do
    if get_total_steam() < @steam_low_mark do
      %State{state | mode: :pump, switching: true}
    else
      state
    end
  end

  defp wait_for_switch(%State{switching: false} = state), do: state

  defp wait_for_switch(%State{mode: :pump, switching: true} = state) do
    cond do
      get_crv_ordered() > 0 ->
        Logger.notice(@log_prefix <> "Steam is low: Closing CRV to run vacuum pump ...")
        set_crv(0)
        state

      get_crv_actual() > 0 ->
        state

      !get_vacuum_pump_active() ->
        Logger.notice(@log_prefix <> "CRV closed, starting vacuum pump ...")
        set_vacuum_pump(true)
        state

      get_vacuum_level() < 0.999 ->
        state

      true ->
        Logger.notice(@log_prefix <> "Vacuum established, now in pump mode.")
        %State{state | switching: false}
    end
  end

  defp wait_for_switch(%State{mode: :crv, switching: true} = state) do
    cond do
      get_vacuum_pump_active() ->
        Logger.notice(@log_prefix <> "Steam is high: Disabling pump and switching to CRV...")
        set_vacuum_pump(false)
        state

      get_crv_ordered() < 100 ->
        Logger.notice(@log_prefix <> "Vacuum pump offline, opening CRV ...")
        set_crv(100)
        state

      get_crv_actual() < 100 ->
        state

      true ->
        Logger.notice(@log_prefix <> "CRV fully opened, now in CRV mode.")
        %State{state | switching: false}
    end
  end

  defp get_control_metrics(:pump), do: {@target_fill_percent, get_fill_percent()}

  defp get_control_metrics(:crv),
    do: {
      @target_vacuum_level * @crv_target_factor,
      get_vacuum_level() * @crv_target_factor
    }

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

  defp get_fill_percent do
    API.get_float("VACUUM_RETENTION_TANK_VOLUME") / @tank_size
  end

  defp get_vacuum_level, do: API.get_float("CONDENSER_VACUUM")

  @omsi "STEAM_EJECTOR_OPERATIONAL_MOTIVE_VALVE"
  @smsi "STEAM_EJECTOR_STARTUP_MOTIVE_VALVE"
  @crv "STEAM_EJECTOR_CONDENSER_RETURN_VALVE"

  defp get_omsi, do: API.get_integer(@omsi <> "_ORDERED")
  defp get_smsi, do: API.get_integer(@smsi <> "_ORDERED")
  defp get_msi, do: {get_omsi(), get_smsi()}

  defp set_omsi(value) when is_integer(value), do: API.put(@omsi, value)
  defp set_smsi(value) when is_integer(value), do: API.put(@smsi, value)
  defp set_crv(value) when is_integer(value), do: API.put(@crv, value)

  defp get_crv_ordered, do: API.get_integer("#{@crv}_ORDERED")
  defp get_crv_actual, do: API.get_integer("#{@crv}_ACTUAL")

  @vacuum_pump "CONDENSER_VACUUM_PUMP_START_STOP"
  defp set_vacuum_pump(true), do: API.put(@vacuum_pump, "START")
  defp set_vacuum_pump(false), do: API.put(@vacuum_pump, "STOP")
  defp get_vacuum_pump_active, do: API.get_boolean("CONDENSER_VACUUM_PUMP_ACTIVE")

  defp get_total_steam do
    0..2
    |> Enum.map(fn loop -> API.get_float_or_nil("STEAM_GEN_#{loop}_OUTLET", 0) end)
    |> Enum.sum()
  end

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
