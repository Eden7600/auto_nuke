defmodule AutoNuke.CoreTemp do
  use GenServer
  require Logger

  defmodule State do
    @enforce_keys [:core, :target, :pid, :temperature, :rods, :offset]
    defstruct(@enforce_keys)
  end

  @log_prefix "[#{inspect(__MODULE__)}] "

  @default_target 285

  def start_link(opts) do
    {core, opts} = Keyword.pop!(opts, :core)
    {target, opts} = Keyword.pop(opts, :target, @default_target)
    GenServer.start_link(__MODULE__, {core, target}, opts)
  end

  def set_target(pid, target) do
    GenServer.cast(pid, {:target, target})
  end

  @impl true
  def init({core, target}) when core in 1..9 do
    rods = get_rods(core)

    state =
      %State{
        core: core,
        target: target,
        pid: PIDControl.new(kp: 0.02, kd: 0.01, ki: 0.0001),
        temperature: get_temperature(core),
        rods: rods,
        offset: calculate_offset(rods)
      }

    Logger.info(
      @log_prefix <>
        "Started with temperature #{state.temperature}°C and rods at #{rods / 10}%."
    )

    PubSub.subscribe(self(), :ticker)
    {:ok, state}
  end

  @impl true
  def handle_cast({:target, t}, state) do
    Logger.info("Target changed from #{state.target}°C to #{t}°C.")
    {:noreply, %State{state | target: t}}
  end

  @impl true
  def handle_info({:tick, _}, state) do
    state =
      get_temperature(state.core)
      |> update_temperature(state)

    {:noreply, state}
  end

  defp update_temperature(new_temp, %State{} = state) do
    pid = state.pid |> PIDControl.step(state.target, new_temp)
    rods = calculate_new_rods(pid.output + state.offset, state.rods)

    # IO.inspect(temp: new_temp, output: pid.output, rods: rods, offset: state.offset)

    %State{state | pid: pid, temperature: new_temp}
    |> update_rods(rods)
    |> adjust_offset(pid.output)
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

  defp calculate_new_rods(output, old) do
    new = 500 - output * 500

    # Compare `new` (a float) to `old` (an integer),
    # and reject the change unless it's almost all the way
    # to the next number in either direction.
    #
    # This avoids oscillations when the float value is
    # hovering just at the `.5` point between two settings.
    if abs(new - old) < 0.95 do
      old
    else
      new
      |> round()
      |> min(1000)
      |> max(0)
    end
  end

  defp calculate_offset(rods) do
    -((rods - 500) / 500)
  end

  # Reduce offset by 1% per update if we're starting to approach the PID limits.
  defp adjust_offset(state, out) do
    if out <= -0.9 or out >= 0.9 do
      old = state.offset
      new = old * 0.99
      Logger.warning(@log_prefix <> "PID at #{out}, reducing offset from #{old} to #{new}.")
      %State{state | offset: new}
    else
      state
    end
  end
end
