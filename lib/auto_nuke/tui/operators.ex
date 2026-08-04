defmodule AutoNuke.Tui.Operators do
  @moduledoc """
  Operator control for the TUI: list, enable/disable, and per-operator
  adjustments.

  Enable/disable goes through `AutoNuke.OperatorSupervisor`
  (`terminate_child`/`restart_child`), so a disabled operator stays down
  until re-enabled, and an enabled one is supervised. Operators running
  *outside* the supervisor (e.g. left over from a standalone startup) can
  be stopped, but starting always goes through the supervisor.

  Adjustments call each operator's public API with its default expiry
  (usually "until the next in-game hour").
  """

  alias AutoNuke.Operator, as: Op

  @supervisor AutoNuke.OperatorSupervisor

  # Supervisor child ids double as registered names.
  @entries [
    {Op.SteamFlow, "SteamFlow", "Works MSCVs and bypass to meet grid power demand"},
    {Op.CoreTemp, "CoreTemp", "Picks the core temp target for 60 bar SG pressure"},
    {Op.ControlRods, "ControlRods", "Moves control rods to hit the core temp target"},
    {Op.PrimaryPumps, "PrimaryPumps", "Scales primary pump speed with core temperature"},
    {Module.concat(Op.SecondaryFill, "L1"), "SecondaryFill L1",
     "Feedwater pump speed to keep steam gen 01 filled"},
    {Module.concat(Op.SecondaryFill, "L2"), "SecondaryFill L2",
     "Feedwater pump speed to keep steam gen 02 filled"},
    {Module.concat(Op.SecondaryFill, "L3"), "SecondaryFill L3",
     "Feedwater pump speed to keep steam gen 03 filled"},
    {Op.VacuumTank, "VacuumTank", "Holds condenser vacuum via OMSI/SMSI valves"},
    {Op.PCSTFill, "PCSTFill", "Keeps the Primary Coolant Storage Tank level in range"},
    {Op.CoreFill, "CoreFill", "Keeps core vessel fill level: pumps in, drains out"},
    {Op.BoronLevel, "BoronLevel", "Doses or filters boron based on rod insertion"},
    {Op.CondenserFill, "CondenserFill", "Keeps condenser level 35-65%: pump or drain"},
    {Op.CondenserCooling, "CondenserCooling", "Runs the cooling pump as slow as it can get away with"},
    {Op.EmergencyPower, "EmergencyPower", "Starts diesel generators on station blackout"},
    {Op.ResistorBanks, "ResistorBanks", "Enables resistor banks when overproducing"},
    {Op.XenonGuard, "XenonGuard", "Watches iodine and xenon; alarms before a stall"}
  ]

  @doc "Current operator list with status."
  def list do
    supervised = supervised_pids()

    Enum.map(@entries, fn {id, label, desc} ->
      status =
        case Process.whereis(id) do
          nil -> :stopped
          pid -> if Map.get(supervised, id) == pid, do: :supervised, else: :unsupervised
        end

      %{id: id, label: label, desc: desc, status: status}
    end)
  end

  defp supervised_pids do
    case Process.whereis(@supervisor) do
      nil ->
        %{}

      _pid ->
        @supervisor
        |> Supervisor.which_children()
        |> Map.new(fn {id, pid, _type, _mods} -> {id, pid} end)
    end
  end

  @doc "Stop a running operator (it stays down until enabled)."
  def disable(id) do
    attempt(fn ->
      case Process.whereis(@supervisor) do
        nil -> plain_stop(id)
        _ -> supervised_stop(id)
      end
    end)
  end

  defp supervised_stop(id) do
    case Supervisor.terminate_child(@supervisor, id) do
      :ok -> :ok
      # Not a supervisor child — a leftover unsupervised operator.
      {:error, :not_found} -> plain_stop(id)
    end
  end

  defp plain_stop(id) do
    case Process.whereis(id) do
      nil -> {:error, "Not running."}
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  end

  @doc "Start a stopped operator under the supervisor."
  def enable(id) do
    attempt(fn ->
      case Process.whereis(@supervisor) do
        nil ->
          {:error, "Supervisor not running — use [s] to start supervised operators."}

        _ ->
          case Supervisor.restart_child(@supervisor, id) do
            {:ok, _pid} -> :ok
            {:error, :running} -> {:error, "Already running."}
            # Never started under this supervisor yet — add its spec.
            {:error, :not_found} -> start_new_child(id)
            {:error, reason} -> {:error, inspect(reason)}
          end
      end
    end)
  end

  defp start_new_child(id) do
    case AutoNuke.OperatorSupervisor.spec_for(id) do
      nil ->
        {:error, "Unknown operator: #{inspect(id)}"}

      spec ->
        case Supervisor.start_child(@supervisor, spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> {:error, "Already running."}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  @doc """
  Adjustment actions for one operator: `%{label, params, run}` where
  `run` takes the list of prompted answers (strings).
  """
  def actions(id) do
    common =
      case list() |> Enum.find(&(&1.id == id)) do
        %{status: :stopped} -> [%{label: "Enable", params: [], run: fn _ -> enable(id) end}]
        %{status: _running} -> [%{label: "Disable", params: [], run: fn _ -> disable(id) end}]
      end

    common ++ extra_actions(id)
  end

  defp extra_actions(Op.SteamFlow) do
    [
      tolerance_action(),
      %{
        label: "Set power override (%)",
        params: [%{label: "Percent", hint: "0-100"}],
        run: fn [p] ->
          attempt(fn -> Op.SteamFlow.set_target_override_percent(to_num(p), :never) end)
        end
      },
      %{
        label: "Set power override (MW)",
        params: [%{label: "Megawatts", hint: "e.g. 120"}],
        run: fn [mw] ->
          attempt(fn -> Op.SteamFlow.set_target_override_mw(to_num(mw), :never) end)
        end
      },
      %{
        label: "Clear power override",
        params: [],
        run: fn _ -> attempt(fn -> Op.SteamFlow.clear_target_override() end) end
      },
      boost_on(fn -> Op.SteamFlow.enable_boost_mode() end),
      boost_off(fn -> Op.SteamFlow.disable_boost_mode() end)
    ]
  end

  defp extra_actions(Op.CoreTemp) do
    [
      %{
        label: "Set temperature override (°C)",
        params: [%{label: "Temperature", hint: "e.g. 330"}],
        run: fn [t] -> attempt(fn -> Op.CoreTemp.set_override(to_num(t), :never) end) end
      },
      %{
        label: "Clear temperature override",
        params: [],
        run: fn _ -> attempt(fn -> Op.CoreTemp.clear_override() end) end
      }
    ]
  end

  defp extra_actions(Op.ControlRods) do
    [
      tolerance_action(),
      %{
        label: "Mode: predictive",
        params: [],
        run: fn _ -> attempt(fn -> Op.ControlRods.set_mode(:predictive) end) end
      },
      %{
        label: "Mode: direct",
        params: [],
        run: fn _ -> attempt(fn -> Op.ControlRods.set_mode(:direct) end) end
      }
    ]
  end

  defp extra_actions(Op.CondenserFill) do
    [
      boost_on(fn -> Op.CondenserFill.enable_boost_mode() end),
      boost_off(fn -> Op.CondenserFill.disable_boost_mode() end)
    ]
  end

  defp extra_actions(Op.CondenserCooling) do
    [
      boost_on(fn -> Op.CondenserCooling.enable_boost_mode() end),
      boost_off(fn -> Op.CondenserCooling.disable_boost_mode() end)
    ]
  end

  defp extra_actions(id) do
    # SecondaryFill.L1..L3 — process_name/1 passes registered names through.
    if id in [
         Module.concat(Op.SecondaryFill, "L1"),
         Module.concat(Op.SecondaryFill, "L2"),
         Module.concat(Op.SecondaryFill, "L3")
       ] do
      [
        boost_on(fn -> Op.SecondaryFill.set_boost_mode(id) end),
        boost_off(fn -> Op.SecondaryFill.clear_boost_mode(id) end)
      ]
    else
      []
    end
  end

  # The global plant-wide tolerance mode, reachable from the operators
  # it affects most. A preference, not an override.
  defp tolerance_action do
    mode = AutoNuke.Tolerance.mode()

    %{
      label: "Tolerance mode: #{mode} — cycle (global)",
      params: [],
      run: fn _ ->
        case AutoNuke.Tolerance.cycle() do
          {:ok, new} -> {:ok, "Tolerance mode: #{new} (global, persisted)"}
          error -> error
        end
      end
    }
  end

  defp boost_on(fun),
    do: %{label: "Boost mode ON (until next hour)", params: [], run: fn _ -> attempt(fun) end}

  defp boost_off(fun), do: %{label: "Boost mode OFF", params: [], run: fn _ -> attempt(fun) end}

  # -- Helpers ----------------------------------------------------------------

  defp to_num(str) do
    case Float.parse(String.trim(str)) do
      {n, ""} -> n
      _ -> raise ArgumentError, "not a number: #{str}"
    end
  end

  # Normalise any operator-API result/crash into :ok | {:error, msg}.
  defp attempt(fun) do
    case fun.() do
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, reason} -> {:error, inspect(reason)}
      _ -> :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, {:noproc, _} -> {:error, "Not running."}
    :exit, reason -> {:error, inspect(reason)}
  end
end
