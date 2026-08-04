defmodule AutoNuke.Operator.ResistorBanks do
  @moduledoc """
  Resistor bank management.

  Resistor banks burn surplus power, but with them enabled the plant only
  targets 100% of demand — power fed to resistors is power not sold. So:
  keep them OFF while supply tracks the target, and switch them ON when
  supply overshoots SteamFlow's current target by a sustained margin.
  Back OFF once supply is no longer overshooting for a sustained stretch.
  Undersupply never enables them — burning power while short only digs
  the hole deeper.
  """

  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Operator.SteamFlow

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Enable when supply overshoots the target beyond this. The plant
  # gets in trouble at 10% over — act before that, not at it.
  @on_deviation 0.08
  # Disable when it sustains at or below this (the gap is the hysteresis):
  @off_deviation 0.06

  # Sustain requirements, in this operator's ticks (≈1 game-second each):
  @on_after 3
  @off_after 30

  # Assume this target when SteamFlow isn't running to tell us:
  @fallback_target 1.0

  defmodule State do
    defstruct high: 0, low: 0, hold: false
  end

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @doc """
  For tasks that drive the banks by hand (loop start/stop): suspend
  automatic control, and `release/1` afterwards to resume it.
  Tolerates the operator not running at all.
  """
  def hold(server \\ __MODULE__), do: set_hold(server, true)
  def release(server \\ __MODULE__), do: set_hold(server, false)

  defp set_hold(server, enabled) do
    GenServer.call(server, {:set_hold, enabled})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def init(nil) do
    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Watching for overproduction.")
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:set_hold, hold}, _from, %State{} = state) do
    if hold != state.hold do
      Logger.notice(
        @log_prefix <>
          if(hold,
            do: "Holding for manual bank control.",
            else: "Resuming automatic control."
          )
      )
    end

    {:reply, :ok, %State{state | hold: hold, high: 0, low: 0}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{hold: true} = state), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    state =
      case supply_ratio() do
        nil -> %State{state | high: 0, low: 0}
        ratio -> track(state, ratio, ratio - target())
      end

    {:noreply, state}
  end

  defp track(%State{} = state, ratio, deviation) do
    state =
      cond do
        deviation > @on_deviation -> %State{state | high: state.high + 1, low: 0}
        # On target or undersupplying — either way, no place for resistors:
        deviation <= @off_deviation -> %State{state | low: state.low + 1, high: 0}
        # In the hysteresis margin: hold both streaks.
        true -> %State{state | high: 0, low: 0}
      end

    cond do
      state.high == @on_after and not enabled?() ->
        Logger.warning(
          @log_prefix <>
            "Supply at #{round(ratio * 100)}% of demand, " <>
            "#{round(deviation * 100)}% over target — enabling resistor banks."
        )

        enable_banks()
        state

      state.low == @off_after and enabled?() ->
        Logger.notice(@log_prefix <> "Supply back on target — disabling resistor banks.")
        disable_banks()
        state

      true ->
        state
    end
  end

  # SteamFlow's current target ratio, when it's around to ask.
  defp target do
    try do
      case GenServer.call(SteamFlow, :get_demand_status, 250) do
        %{target: target} when is_number(target) -> target
        _ -> @fallback_target
      end
    catch
      :exit, _ -> @fallback_target
    end
  end

  defp supply_ratio do
    demand = API.Power.get_demand_kw()

    if demand > 0 do
      supply() / demand
    else
      nil
    end
  end

  # Net export: generator output minus the plant's own draw.
  defp supply do
    generated =
      1..3
      |> Enum.map(fn loop -> API.get_float_or_nil("GENERATOR_#{loop - 1}_KW", 0.0) end)
      |> Enum.sum()

    generated - API.Power.get_used_kw()
  end

  def enabled?, do: API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH")

  def enable_banks do
    API.put("RESISTOR_BANKS_MAIN_SWITCH", true)

    API.get_json("RESISTOR_BANKS_JSON")
    |> Map.fetch!("resistors")
    |> Enum.each(fn {"Resistor_Bank_" <> num, bank} ->
      if Map.fetch!(bank, "IsInstalled") != 0 do
        API.put("RESISTOR_BANK_#{num}_SWITCH", true)
      end
    end)
  end

  def disable_banks do
    1..4 |> Enum.each(&API.put("RESISTOR_BANK_0#{&1}_SWITCH", false))
    API.put("RESISTOR_BANKS_MAIN_SWITCH", false)
  end
end
