defmodule AutoNuke.API.Misc do
  alias AutoNuke.API

  def get_time_stamp, do: API.get_integer("TIME_STAMP")
  def ambient_temperature, do: API.get_float("AMBIENT_TEMPERATURE")

  # Momentary buttons: the game ignores the value, POSTing presses them.
  def press_scram, do: API.put("CORE_SCRAM_BUTTON", "PRESS")
  def trip_turbines, do: API.put("STEAM_TURBINE_TRIP", "PRESS")
end
