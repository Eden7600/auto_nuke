defmodule AutoNuke.Operator.ResistorBanks do
  @moduledoc """
  Resistor bank management.

  Resistor banks burn surplus power, but with them enabled the plant only
  targets 100% of demand — power fed to resistors is power not sold. So:
  keep them OFF while supply tracks the target, and switch them ON
  whenever supply strays outside ±10% of SteamFlow's current target —
  overproduction *or* an aggressive catch-up transient both count. Back
  OFF once supply has hugged the target again for a sustained stretch.
  """

  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API
  alias AutoNuke.Operator.SteamFlow

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Enable when |supply ratio - target| sustains beyond this. The plant
  # gets in trouble at 10% off — act before that, not at it.
  @on_deviation 0.08
  # Disable when it sustains within this (the gap is the hysteresis):
  @off_deviation 0.06

  # Sustain requirements, in this operator's ticks (≈1 game-second each):
  @on_after 3
  @off_after 30

  # Assume this target when SteamFlow isn't running to tell us:
  @fallback_target 1.0

  defmodule State do
    defstruct high: 0, low: 0
  end

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl true
  def init(nil) do
    PubSub.subscribe(self(), :ticker)
    Logger.info(@log_prefix <> "Watching for overproduction.")
    {:ok, %State{}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

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
        abs(deviation) > @on_deviation -> %State{state | high: state.high + 1, low: 0}
        abs(deviation) <= @off_deviation -> %State{state | low: state.low + 1, high: 0}
        # In the hysteresis margin: hold both streaks.
        true -> %State{state | high: 0, low: 0}
      end

    cond do
      state.high == @on_after and not enabled?() ->
        Logger.warning(
          @log_prefix <>
            "Supply at #{round(ratio * 100)}% of demand, " <>
            "#{round(deviation * 100)}% off target — enabling resistor banks."
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

  # Also used by XenonGuard's burn-off procedure.
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
