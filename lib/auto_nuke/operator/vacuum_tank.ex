defmodule AutoNuke.Operator.VacuumTank do
  use GenServer
  require Logger

  # Run on the fifth and final tick each second:
  defguard is_my_tick(t) when rem(t, 5) == 4

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

  @retention_tank API.Vessels.retention_tank()
  @steam_gens API.SteamGen.all()
  @omsi API.Valves.omsi()
  @smsi API.Valves.smsi()
  @crv API.Valves.crv()

  # In pump mode, we try to keep the retention tank half full:
  @target_fill_ratio 0.5
  # In CRV mode, we try to keep vacuum at 99% (as opposed to 99.9%):
  @target_vacuum_level 0.99
  # Vacuum level is a lot more precise than tank fill level,
  # so to keep all the AxisController parameters the same
  # (especially deadzone), we scale up our current and target
  # vacuum level by an order of magnitude.
  @crv_target_factor 10

  # If running in pump mode and steam climbs past this (kg/min), switch to CRV mode.
  @steam_high_mark 130
  # If running in CRV mode and steam drops below this (kg/min), switch to pump mode.
  @steam_low_mark 110

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
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
    fill_level = get_fill_ratio() |> Float.round(2)
    Logger.info(@log_prefix <> "Started with fill level of #{fill_level * 100}%.")
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

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

      !API.VacuumPump.get_active?() ->
        Logger.notice(@log_prefix <> "CRV closed, starting vacuum pump ...")
        API.VacuumPump.start()
        state

      API.VacuumPump.get_vacuum_level() < 0.999 ->
        state

      true ->
        Logger.notice(@log_prefix <> "Vacuum established, now in pump mode.")
        %State{state | switching: false}
    end
  end

  defp wait_for_switch(%State{mode: :crv, switching: true} = state) do
    cond do
      API.VacuumPump.get_active?() ->
        Logger.notice(@log_prefix <> "Steam is high: Disabling pump and switching to CRV...")
        API.VacuumPump.stop()
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

  defp get_control_metrics(:pump), do: {@target_fill_ratio, get_fill_ratio()}

  defp get_control_metrics(:crv),
    do: {
      @target_vacuum_level * @crv_target_factor,
      API.VacuumPump.get_vacuum_level() * @crv_target_factor
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

  defp get_fill_ratio, do: API.Vessels.get_fill_ratio(@retention_tank)

  defp get_omsi, do: API.Valves.get_open_percent(@omsi)
  defp get_smsi, do: API.Valves.get_open_percent(@smsi)
  defp get_msi, do: {get_omsi(), get_smsi()}

  defp set_omsi(value) when is_integer(value), do: API.Valves.set_open_percent(@omsi, value)
  defp set_smsi(value) when is_integer(value), do: API.Valves.set_open_percent(@smsi, value)
  defp set_crv(value) when is_integer(value), do: API.Valves.set_open_percent(@crv, value)

  defp get_crv_ordered, do: API.Valves.get_ordered_open_percent(@crv)
  defp get_crv_actual, do: API.Valves.get_open_percent(@crv)

  defp get_total_steam do
    @steam_gens
    |> Enum.map(&API.SteamGen.get_outlet/1)
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
