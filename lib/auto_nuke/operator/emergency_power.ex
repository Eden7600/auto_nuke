defmodule AutoNuke.Operator.EmergencyPower do
  @moduledoc """
  Backup power management.

  Watches where the plant's internal supply comes from. When neither the
  external grid nor the plant's own turbines are feeding it (a station
  blackout — batteries draining), starts the emergency diesel generators;
  once normal supply returns, stops the generators it started. Generators
  the human started stay untouched.

  Also nags about low diesel fuel and pending generator maintenance.
  """

  use GenServer
  use AutoNuke.Operator
  require Logger

  alias AutoNuke.API

  @log_prefix "[#{inspect(__MODULE__)}] " |> String.replace("AutoNuke.Operator.", "")

  @generators [1, 2]

  # Ticks of sustained state before acting (one tick ≈ one game second):
  @blackout_after 3
  @recovery_after 5

  # Nag below this much diesel:
  @low_fuel 100

  defmodule State do
    defstruct abnormal: 0, normal: 0, started_by_us: [], warned: MapSet.new()
  end

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  # Absent equipment reads as "null" (same convention as rod banks).
  @not_installed ["null", ""]

  @impl true
  def init(nil) do
    PubSub.subscribe(self(), :ticker)

    installed = generator_statuses() |> Enum.map(&elem(&1, 0))
    batteries = if batteries_installed?(), do: "present", else: "none"

    Logger.info(
      @log_prefix <>
        "Watching for station blackout " <>
        "(generators: #{inspect(installed)}, batteries: #{batteries})."
    )

    {:ok, %State{}}
  end

  @impl true
  def handle_info({:tick, t}, state) when not is_my_tick(t), do: {:noreply, state}

  @impl true
  def handle_info({:tick, _}, %State{} = state) do
    generators = generator_statuses()

    state =
      state
      |> track_supply(normal_supply?())
      |> maybe_start_generators(generators)
      |> maybe_stop_generators(generators)
      |> check_generator_health(generators)

    {:noreply, state}
  end

  # `{gen, status}` for each generator that is actually installed.
  defp generator_statuses do
    @generators
    |> Enum.map(&{&1, API.get_string("EMERGENCY_GENERATOR_#{&1}_STATUS")})
    |> Enum.reject(fn {_gen, status} -> status in @not_installed end)
  end

  defp batteries_installed? do
    API.get_string("EMERGENCY_BATTERIES_MODE") not in @not_installed
  end

  # Normal = the grid or our own turbines are carrying the plant load.
  # While the diesels carry it, this stays false — recovery is only
  # declared when a *real* source returns.
  defp normal_supply? do
    API.Power.get_external_used_kw() > 0 or API.Power.get_used_kw() > 0
  end

  defp track_supply(%State{} = state, true),
    do: %State{state | normal: state.normal + 1, abnormal: 0}

  defp track_supply(%State{} = state, false),
    do: %State{state | abnormal: state.abnormal + 1, normal: 0}

  defp maybe_start_generators(%State{abnormal: @blackout_after} = state, generators) do
    idle = for {gen, "INACTIVO"} <- generators, do: gen

    cond do
      generators == [] ->
        Logger.warning(
          @log_prefix <> "Station blackout — and no emergency generators are installed!"
        )

        state

      idle == [] ->
        state

      true ->
        Logger.warning(
          @log_prefix <> "Station blackout — starting emergency generator(s) #{inspect(idle)}."
        )

        Enum.each(idle, &API.put("EMERGENCY_GENERATOR_#{&1}_START_STOP", "START"))
        %State{state | started_by_us: Enum.uniq(state.started_by_us ++ idle)}
    end
  end

  defp maybe_start_generators(state, _generators), do: state

  defp maybe_stop_generators(
         %State{normal: @recovery_after, started_by_us: [_ | _]} = state,
         generators
       ) do
    statuses = Map.new(generators)

    # Unknown/uninstalled counts as not running — nothing to stop.
    running =
      Enum.filter(state.started_by_us, &(Map.get(statuses, &1, "INACTIVO") != "INACTIVO"))

    if running != [] do
      Logger.notice(
        @log_prefix <> "Normal supply restored — stopping emergency generator(s) #{inspect(running)}."
      )

      Enum.each(running, &API.put("EMERGENCY_GENERATOR_#{&1}_START_STOP", "STOP"))
    end

    %State{state | started_by_us: []}
  end

  defp maybe_stop_generators(state, _generators), do: state

  defp check_generator_health(%State{} = state, generators) do
    Enum.reduce(generators, state, fn {gen, _status}, acc ->
      acc
      |> warn_once({:fuel, gen}, fn ->
        API.get_float("EMERGENCY_GENERATOR_#{gen}_FUEL") < @low_fuel
      end, "Emergency generator #{gen} is low on fuel.")
      |> warn_once({:maintenance, gen}, fn ->
        API.get_boolean("EMERGENCY_GENERATOR_#{gen}_MAINTENANCE_NEEDED")
      end, "Emergency generator #{gen} needs maintenance.")
    end)
  end

  # Warn when a condition becomes true; re-arm once it clears.
  defp warn_once(%State{warned: warned} = state, key, check, message) do
    case {check.(), key in warned} do
      {true, false} ->
        Logger.warning(@log_prefix <> message)
        %State{state | warned: MapSet.put(warned, key)}

      {false, true} ->
        %State{state | warned: MapSet.delete(warned, key)}

      _ ->
        state
    end
  end
end
