defmodule AutoNuke.API.Generator do
  alias AutoNuke.API

  @loops 1..3

  def get_volts(loop) when loop in @loops, do: API.get_float("GENERATOR_#{loop - 1}_V")
  def get_amps(loop) when loop in @loops, do: API.get_float("GENERATOR_#{loop - 1}_A")
  def get_hertz(loop) when loop in @loops, do: API.get_float("GENERATOR_#{loop - 1}_HERTZ")
  def get_power_kw(loop) when loop in @loops, do: API.get_float("GENERATOR_#{loop - 1}_KW")

  def get_is_connected(loop) when loop in @loops,
    do: !API.get_boolean("GENERATOR_#{loop - 1}_BREAKER")
end
