defmodule AutoNuke.API.VacuumPump do
  alias AutoNuke.API

  @start_stop "CONDENSER_VACUUM_PUMP_START_STOP"
  def start, do: API.put(@start_stop, "START")
  def stop, do: API.put(@start_stop, "STOP")

  def get_active?, do: API.get_boolean("CONDENSER_VACUUM_PUMP_ACTIVE")
  def get_vacuum_level, do: API.get_float("CONDENSER_VACUUM")

  @get_modes %{
    "STARTUP" => :startup,
    "OPERACIONAL" => :operational
  }

  @valid_modes Map.values(@get_modes)
  @set_modes @valid_modes
             |> Map.new(fn mode ->
               {mode, mode |> Atom.to_string() |> String.upcase()}
             end)

  def get_mode do
    Map.fetch!(@get_modes, API.get_string("CONDENSER_VACUUM_PUMP_MODE"))
  end

  def set_mode(mode) when mode in @valid_modes do
    API.put("CONDENSER_VACUUM_PUMP_MODE", Map.fetch!(@set_modes, mode))
  end
end
