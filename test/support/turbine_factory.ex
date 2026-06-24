defmodule AutoNuke.Test.TurbineFactory do
  alias AutoNuke.Operator.SteamFlow.Turbine
  alias AutoNuke.Test.MockAPI, as: API

  @secondary_pumps [200, 300]

  def create(opts \\ []) do
    {loop, opts} = maybe_random(opts, :loop, 1..3)
    {power_level, opts} = maybe_random(opts, :power_level, 2..30)
    {min_steam, opts} = maybe_random(opts, :min_steam, 1..50)
    {bypass, opts} = maybe_random(opts, :bypass, 0..100)
    {pressure, opts} = Keyword.pop_lazy(opts, :pressure, &random_pressure/0)
    {secondary_pump, opts} = maybe_random(opts, :secondary_pump, @secondary_pumps)
    {mock_only, opts} = Keyword.pop(opts, :mock_only, false)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    API.mock_get("COOLANT_SEC_CIRCULATION_PUMP_#{loop - 1}_CAPACITY", secondary_pump)
    API.mock_get("MSCV_#{loop - 1}_OPENING_ACTUAL", power_level)
    API.mock_get("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL", bypass)
    API.mock_get("COOLANT_SEC_#{loop - 1}_PRESSURE", pressure)
    API.mock_get("STEAM_GEN_#{loop - 1}_OUTLET", 50)

    unless mock_only do
      %Turbine{} = turbine = Turbine.new(loop) |> Turbine.set_min_steam(min_steam)
      [] = API.unused_mocks()
      turbine
    end
  end

  defp maybe_random(opts, key, _.._//_ = range) do
    maybe_random(opts, key, fn -> Enum.random(range) end)
  end

  defp maybe_random(opts, key, list) when is_list(list) do
    maybe_random(opts, key, fn -> Enum.random(list) end)
  end

  defp maybe_random(opts, key, fun) when is_function(fun) do
    Keyword.pop_lazy(opts, key, fun)
  end

  # Random float between 45 and 75.
  def random_pressure, do: :rand.uniform() * 30 + 45
end
