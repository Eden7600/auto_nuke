defmodule AutoNuke.API.Misc do
  alias AutoNuke.API

  def get_time_stamp, do: API.get_integer("TIME_STAMP")
  def ambient_temperature, do: API.get_float("AMBIENT_TEMPERATURE")
end
