defmodule AutoNuke.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:core, :pid, :temperature, :rods, :offset]
    defstruct(@enforce_keys)
  end

  @log_prefix "[#{inspect(__MODULE__)}] "
  @loop_every 100

  @target_temperature 300

  def start_link(opts) do
    {core, opts} = Keyword.pop!(opts, :core)
    GenServer.start_link(__MODULE__, core, opts)
  end

  @impl true
  def init(core) when core in 1..9 do
    rods = get_rods(core)

    state =
      %State{
        core: core,
        pid: PIDControl.new(kp: 0.01, kd: 0, ki: 0),
        temperature: get_temperature(core),
        rods: rods,
        offset: calculate_offset(rods)
      }

    Logger.info(
      @log_prefix <>
        "Started with temperature #{state.temperature}°C and rods at #{rods / 10}%."
    )

    {:ok, state, {:continue, :loop}}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      get_temperature(state.core)
      |> update_temperature(state)

    {:noreply, state, {:continue, :loop}}
  end

  @impl true
  def handle_continue(:loop, state) do
    Process.send_after(self(), :loop, @loop_every)
    {:noreply, state}
  end

  defp update_temperature(temp, %State{temperature: temp} = state) do
    # Nothing changed.
    state
  end

  defp update_temperature(new_temp, %State{} = state) do
    pid = state.pid |> PIDControl.step(@target_temperature, new_temp)
    rods = calculate_new_rods(pid.output + state.offset)

    IO.inspect(temp: new_temp, output: pid.output, rods: rods, offset: state.offset)

    %State{state | pid: pid, temperature: new_temp, offset: state.offset * 0.999}
    |> update_rods(rods)
  end

  defp update_rods(%State{rods: same} = state, same), do: state

  defp update_rods(%State{core: core, rods: old} = state, new) do
    Logger.info(
      @log_prefix <> "Changing core #{core} control rods from #{old / 10}% to #{new / 10}%."
    )

    set_rods(core, new)
    %State{state | rods: new}
  end

  defp get_temperature(_core) do
    AutoNuke.API.get_float("CORE_TEMP")
  end

  # Expressed as an integer from 0..1000 where 12.3 = 123.
  defp get_rods(core) do
    AutoNuke.API.get_float("ROD_BANK_POS_#{core - 1}_ORDERED")
    |> Kernel.*(10)
    |> round()
  end

  defp set_rods(core, value) when value in 0..1000 do
    AutoNuke.API.put("ROD_BANK_POS_#{core - 1}_ORDERED", value / 10.0)
  end

  defp calculate_new_rods(output) do
    (500 - output * 500)
    |> round()
    |> min(1000)
    |> max(0)
  end

  defp calculate_offset(rods) do
    -((rods - 500) / 500)
  end
end
