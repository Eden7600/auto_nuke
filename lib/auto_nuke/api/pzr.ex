defmodule AutoNuke.API.Pzr do
  alias AutoNuke.API
  alias AutoNuke.API.Vessels

  @pzr Vessels.pressurizer()

  def get_heat_enabled?, do: API.get_boolean("PRESSURIZER_HEATERS_ON")
  def get_temperature, do: Vessels.get_temperature(@pzr)
  def get_pressure, do: Vessels.get_pressure(@pzr)

  def get_thermostat_enabled? do
    API.get_json("AO_AGENT_DIAGNOSTICS_JSON")
    |> Map.fetch!("pressurizer_state")
    |> Map.fetch!("auto_thermostat")
  end
end
