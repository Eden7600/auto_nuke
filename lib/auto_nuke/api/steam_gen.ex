defmodule AutoNuke.API.SteamGen do
  alias AutoNuke.API

  @enforce_keys [:loop, :vessel, :pump, :mscv, :bypass]
  defstruct(@enforce_keys)
  alias __MODULE__

  @loops 1..3
  def for_loop(loop) when loop in @loops do
    %SteamGen{
      loop: loop,
      vessel: API.Vessels.steam_generator(loop),
      pump: API.Pumps.secondary(loop),
      mscv: API.Valves.mscv(loop),
      bypass: API.Valves.turbine_bypass(loop)
    }
  end

  def all, do: @loops |> Enum.map(&for_loop/1)

  def get_outlet(%SteamGen{loop: loop}) do
    API.get_float("STEAM_GEN_#{loop - 1}_OUTLET")
  end

  def get_total_outlet, do: all() |> Enum.map(&get_outlet/1) |> Enum.sum()

  def get_temperature(%SteamGen{vessel: vessel}), do: API.Vessels.get_temperature(vessel)
  def get_pressure(%SteamGen{vessel: vessel}), do: API.Vessels.get_pressure(vessel)

  def get_vent_open?(%SteamGen{loop: loop}),
    do: API.get_boolean("STEAM_GEN_#{loop - 1}_VENT_SWITCH")

  def set_vent_open(%SteamGen{loop: loop}, open),
    do: API.put("STEAM_GEN_#{loop - 1}_VENT_SWITCH", open)
end
