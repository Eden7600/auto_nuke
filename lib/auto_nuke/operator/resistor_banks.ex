defmodule AutoNuke.Operator.ResistorBanks do
  @moduledoc """
  Overproduction protection.

  Resistor banks burn surplus power, but with them enabled the plant only
  targets 100% of demand — power fed to resistors is power not sold. So:
  keep them OFF in steady state, and switch them ON when the supply ratio
  climbs toward the 110% scoring ceiling; back OFF once things have been
  calm for a while. Hysteresis between the two thresholds prevents
  flapping against SteamFlow's resistor-aware targeting.
  """

  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  # Enable when supply/demand sustains above this (band ceiling is 1.10):
  @on_ratio 1.08
  # Disable when it sustains at/below this (resistor-mode target is 1.02,
  # steady no-resistor target is 1.05 — the gap is the hysteresis):
  @off_ratio 1.04

  # Sustain requirements, in this operator's ticks (≈1 game-second each):
  @on_after 3
  @off_after 30

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
        ratio -> track(state, ratio)
      end

    {:noreply, state}
  end

  defp track(%State{} = state, ratio) do
    state =
      cond do
        ratio >= @on_ratio -> %State{state | high: state.high + 1, low: 0}
        ratio <= @off_ratio -> %State{state | low: state.low + 1, high: 0}
        true -> %State{state | high: 0, low: 0}
      end

    cond do
      state.high == @on_after and not enabled?() ->
        Logger.warning(
          @log_prefix <>
            "Supply at #{round(ratio * 100)}% of demand — enabling resistor banks."
        )

        enable_banks()
        state

      state.low == @off_after and enabled?() ->
        Logger.notice(@log_prefix <> "Supply stable — disabling resistor banks.")
        disable_banks()
        state

      true ->
        state
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

  defp enabled?, do: API.get_boolean("RESISTOR_BANKS_MAIN_SWITCH")

  defp enable_banks do
    API.put("RESISTOR_BANKS_MAIN_SWITCH", true)

    API.get_json("RESISTOR_BANKS_JSON")
    |> Map.fetch!("resistors")
    |> Enum.each(fn {"Resistor_Bank_" <> num, bank} ->
      if Map.fetch!(bank, "IsInstalled") != 0 do
        API.put("RESISTOR_BANK_#{num}_SWITCH", true)
      end
    end)
  end

  defp disable_banks do
    1..4 |> Enum.each(&API.put("RESISTOR_BANK_0#{&1}_SWITCH", false))
    API.put("RESISTOR_BANKS_MAIN_SWITCH", false)
  end
end
