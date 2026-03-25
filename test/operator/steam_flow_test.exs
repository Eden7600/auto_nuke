defmodule AutoNuke.Operator.SteamFlowTest do
  use ExUnit.Case, async: true
  alias AutoNuke.Operator.SteamFlow
  alias AutoNuke.Operator.SteamFlow.Turbine
  alias AutoNuke.Test.MockGenServer
  alias AutoNuke.Test.TurbineFactory
  alias AutoNuke.Test.MockAPI, as: API

  describe "start_link/1" do
    test "takes control of turbines with closed breakers" do
      pid =
        start_steam_flow(
          turbine1: [power_level: 5, bypass: 5],
          turbine2: false,
          turbine3: [power_level: 3, bypass: 10]
        )

      assert [t1, t3] = state(pid).turbines

      assert t1.loop == 1
      assert t1.power_level == 5
      assert t1.min_steam == 25
      assert t1.bypass == 5

      assert t3.loop == 3
      assert t3.power_level == 3
      assert t3.min_steam == 25
      assert t3.bypass == 10
    end
  end

  describe "add_loop/1" do
    setup do
      [pid: start_steam_flow(turbine1: false, turbine3: false)]
    end

    test "begins managing new turbine", %{pid: pid} do
      # Start with just turbine 2:
      assert [%Turbine{loop: 2}] = state(pid).turbines

      # Add turbine 1:
      TurbineFactory.create(loop: 1, mock_only: true)
      assert :ok = SteamFlow.add_loop(1, pid)

      # Verify we have turbines 1 and 2:
      assert [%Turbine{loop: 1}, %Turbine{loop: 2}] = state(pid).turbines
    end

    test "updates minimum steam flow on all turbines", %{pid: pid} do
      assert [%Turbine{min_steam: 50.0}] = state(pid).turbines

      TurbineFactory.create(loop: 1, mock_only: true)
      assert :ok = SteamFlow.add_loop(1, pid)
      assert [%Turbine{min_steam: 25.0}, %Turbine{min_steam: 25.0}] = state(pid).turbines

      TurbineFactory.create(loop: 3, mock_only: true)
      assert :ok = SteamFlow.add_loop(3, pid)
      assert [t1, t2, t3] = state(pid).turbines
      assert_in_delta t1.min_steam, 16.66666, 0.0001
      assert_in_delta t2.min_steam, 16.66666, 0.0001
      assert_in_delta t3.min_steam, 16.66666, 0.0001
    end

    test "returns error when turbine already added", %{pid: pid} do
      assert {:error, :already_active} = SteamFlow.add_loop(2, pid)
    end
  end

  describe "remove_loop/1" do
    setup do
      [pid: start_steam_flow(turbine1: false)]
    end

    test "stops managing specified turbine", %{pid: pid} do
      # Start with turbines 2 and 3:
      assert [%Turbine{loop: 2}, %Turbine{loop: 3}] = state(pid).turbines

      # Remove turbine 2:
      assert :ok = SteamFlow.remove_loop(2, pid)

      # Verify we have only turbine 3:
      assert [%Turbine{loop: 3}] = state(pid).turbines
    end

    test "returns error when turbine not active", %{pid: pid} do
      assert {:error, :not_active} = SteamFlow.remove_loop(1, pid)
    end

    test "updates minimum steam flow on all turbines", %{pid: pid} do
      # Verify old steam flow:
      assert [%Turbine{min_steam: 25.0}, %Turbine{min_steam: 25.0}] = state(pid).turbines

      # Remove turbine 3:
      assert :ok = SteamFlow.remove_loop(3, pid)

      # Verify minimum steam flow has increased:
      assert [%Turbine{min_steam: 50.0}] = state(pid).turbines
    end
  end

  defp start_steam_flow(opts) do
    {turbine1, opts} = Keyword.pop(opts, :turbine1, [])
    {turbine2, opts} = Keyword.pop(opts, :turbine2, [])
    {turbine3, opts} = Keyword.pop(opts, :turbine3, [])
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    [turbine1, turbine2, turbine3]
    |> Enum.with_index(1)
    |> Enum.each(fn
      {false, loop} ->
        API.mock_get("GENERATOR_#{loop - 1}_BREAKER", "True")

      {t_opts, loop} when is_list(t_opts) ->
        API.mock_get("GENERATOR_#{loop - 1}_BREAKER", "False")

        t_opts
        |> Keyword.put(:mock_only, true)
        |> Keyword.put(:loop, loop)
        |> TurbineFactory.create()
    end)

    test_pid = self()

    mock_pid =
      start_link_supervised!(
        {MockGenServer,
         module: SteamFlow,
         before_init: fn ->
           API.register_alias(self(), test_pid)
         end}
      )

    assert [] = API.unused_mocks()
    mock_pid
  end

  defp state(pid) do
    assert %SteamFlow.State{} = MockGenServer.get_state(pid)
  end
end
