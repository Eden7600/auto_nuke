defmodule AutoNuke.API.Power do
  alias AutoNuke.API

  def get_demand_mw, do: API.get_float("POWER_DEMAND_MW")
  def get_demand_kw, do: get_demand_mw() * 1000
  def get_used_kw, do: API.get_float("POWER_FROM_TURBINE_KW")
  def get_external_used_kw, do: API.get_float("POWER_FROM_EXTERNAL_KW")
end
