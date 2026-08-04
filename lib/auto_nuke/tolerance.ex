defmodule AutoNuke.Tolerance do
  @moduledoc """
  The plant-wide tolerance mode: how tightly the control system chases
  its targets.

    * `:exact` — hunt as much as needed for perfect values: narrow
      deadzones, no command gating, no target hysteresis.
    * `:normal` — the tuned defaults.
    * `:steady` — patient: wide deadzones and strong gating. Values are
      allowed to drift a little further so that everything moves less.

  Replaces the per-operator "anti-hunting" toggles, which never worked
  well in isolation — holding rod commands is pointless while the
  temperature target itself swings. Tolerance scales the whole chain:
  how the temperature target is built (CoreTemp's deadzone), how it is
  accepted (ControlRods' target hysteresis), how rods move (calm-zone
  gating), how pumps follow (PrimaryPumps' deadband), and how power is
  re-allocated (SteamFlow's deadzone and hold).

  Like anti-hunting, this is a player preference rather than an
  override: it changes how fidgety the plant is, not what it does.

  Operators read the mode through the scaling helpers on every tick, so
  a change applies immediately. When the registry isn't running (legacy
  VMs, tests), everything falls back to `:normal`.
  """

  use GenServer
  require Logger

  @modes [:exact, :normal, :steady]
  def modes, do: @modes

  @setting "tolerance_mode"
  def setting, do: @setting

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def mode(server \\ __MODULE__) do
    GenServer.call(server, :mode)
  catch
    :exit, _ -> :normal
  end

  def set_mode(mode, server \\ __MODULE__) when mode in @modes do
    GenServer.call(server, {:set_mode, mode})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Advance to the next mode; returns `{:ok, new_mode}`."
  def cycle(server \\ __MODULE__) do
    GenServer.call(server, :cycle)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # -- Scaling helpers --------------------------------------------------

  @doc """
  Scale a PID deadzone: how far off target counts as close enough.
  Accepts the `{lower, upper}` tuple form ControlAxis understands.
  """
  def deadzone(base), do: scale_deadzone(base, mode())

  defp scale_deadzone({lower, upper}, mode),
    do: {scale_deadzone(lower, mode), scale_deadzone(upper, mode)}

  defp scale_deadzone(base, :exact), do: base * 0.25
  defp scale_deadzone(base, :normal), do: base
  defp scale_deadzone(base, :steady), do: base * 2.0

  @doc """
  Scale a hysteresis width or command gate. `:exact` disables gating
  entirely — every change goes through.
  """
  def hysteresis(base) do
    case mode() do
      :exact -> base * 0.0
      :normal -> base
      :steady -> base * 2.0
    end
  end

  @doc """
  SteamFlow's re-allocation gate: how many total power levels of drift
  to tolerate before re-allocating. 0 means never hold.
  """
  def min_power_move do
    case mode() do
      :exact -> 0
      :normal -> 2
      :steady -> 3
    end
  end

  @impl true
  def init(nil) do
    mode =
      case AutoNuke.Settings.get(@setting, "normal") do
        "exact" -> :exact
        "steady" -> :steady
        _ -> :normal
      end

    {:ok, mode}
  end

  @impl true
  def handle_call(:mode, _from, mode), do: {:reply, mode, mode}

  @impl true
  def handle_call({:set_mode, new}, _from, old) do
    {:reply, :ok, change(old, new)}
  end

  @impl true
  def handle_call(:cycle, _from, old) do
    new = next(old)
    {:reply, {:ok, new}, change(old, new)}
  end

  defp change(old, old), do: old

  defp change(old, new) do
    Logger.notice("[Tolerance] Mode #{old} -> #{new}.")
    AutoNuke.Settings.put(@setting, Atom.to_string(new))
    new
  end

  defp next(mode) do
    i = Enum.find_index(@modes, &(&1 == mode))
    Enum.at(@modes, rem(i + 1, length(@modes)))
  end
end
