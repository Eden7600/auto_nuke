defmodule AutoNuke.Test.TurbineFactory do
  alias AutoNuke.Operator.SteamFlow.Turbine
  alias AutoNuke.Test.MockAPI, as: API

  def create(opts \\ []) do
    {loop, opts} = maybe_random(opts, :loop, 1..3)
    {power_level, opts} = maybe_random(opts, :power_level, 0..100)
    {min_steam, opts} = maybe_random(opts, :min_steam, 1..100)
    {bypass, opts} = maybe_random(opts, :bypass, 0..100)
    {torque, opts} = maybe_random(opts, :torque, fn -> random_torque(power_level) end)
    {mock_only, opts} = Keyword.pop(opts, :mock_only, false)
    unless Enum.empty?(opts), do: raise("Unknown options: #{inspect(opts)}")

    mscv =
      if power_level in 1..2 do
        API.mock_get("STEAM_TURBINE_#{loop - 1}_TORQUE", torque)
        2
      else
        power_level
      end

    API.mock_get("MSCV_#{loop - 1}_OPENING_ACTUAL", mscv)
    API.mock_get("STEAM_TURBINE_#{loop - 1}_BYPASS_ACTUAL", bypass)

    unless mock_only do
      %Turbine{} = turbine = Turbine.new(loop, min_steam)
      [] = API.unused_mocks()
      turbine
    end
  end

  defp maybe_random(opts, key, _.._//_ = range) do
    maybe_random(opts, key, fn -> Enum.random(range) end)
  end

  defp maybe_random(opts, key, fun) when is_function(fun) do
    Keyword.pop_lazy(opts, key, fun)
  end

  defp random_torque(1), do: 2.000 + :rand.uniform() * 0.699
  defp random_torque(_), do: 2.701 + :rand.uniform() * 5
end
