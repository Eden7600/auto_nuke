defmodule AutoNuke.Operator.SteamFlowTest do
  use ExUnit.Case, async: true

  alias AutoNuke.Operator.SteamFlow, as: SF

  # approximate
  @cutover -0.892617

  describe "axis_to_valves/1" do
    test "converts min axis to max bypass + min MSCV" do
      assert [same, same, same] = SF.axis_to_valves(-1.0)
      assert same == {80, 3}
    end

    test "converts max axis to min bypass + max MSCV" do
      assert [same, same, same] = SF.axis_to_valves(1.0)
      assert same == {0, 50}
    end

    test "converts cutover point to min bypass + min MSCV" do
      assert [same, same, same] = SF.axis_to_valves(@cutover)
      assert same == {0, 3}
    end

    test "above cutover point, increases MSCV one valve at a time" do
      assert number_stream(@cutover, fn n -> n + 0.005 end)
             |> Stream.map(&SF.axis_to_valves/1)
             |> Stream.dedup()
             |> Enum.take(5) == [
               [{0, 3}, {0, 3}, {0, 3}],
               [{0, 4}, {0, 3}, {0, 3}],
               [{0, 4}, {0, 4}, {0, 3}],
               [{0, 4}, {0, 4}, {0, 4}],
               [{0, 5}, {0, 4}, {0, 4}]
             ]
    end

    test "below cutover point, increases bypass on all valves at once" do
      assert number_stream(@cutover, fn n -> n - 0.0005 end)
             |> Stream.map(&SF.axis_to_valves/1)
             |> Stream.dedup()
             |> Enum.take(5) == [
               [{0, 3}, {0, 3}, {0, 3}],
               [{1, 3}, {1, 3}, {1, 3}],
               [{2, 3}, {2, 3}, {2, 3}],
               [{3, 3}, {3, 3}, {3, 3}],
               [{4, 3}, {4, 3}, {4, 3}]
             ]
    end
  end

  describe "valves_to_axis/2" do
    test "converts max bypass + min MSCV to min axis" do
      min = {80, 3}
      assert_in_delta SF.valves_to_axis([min, min, min], 1..3), -1.0, 0.00001
    end

    test "converts min bypass + max MSCV to min axis" do
      min = {0, 50}
      assert_in_delta SF.valves_to_axis([min, min, min], 1..3), 1.0, 0.00001
    end

    test "converts min bypass + min MSCV to cutover point" do
      min = {0, 3}
      assert_in_delta SF.valves_to_axis([min, min, min], 1..3), @cutover, 0.001
    end
  end

  test "axis_to_valves/1 + valves_to_axis/2 = same value" do
    1..100
    |> Enum.each(fn _ ->
      input = :rand.uniform() * 2 - 1
      output = input |> SF.axis_to_valves() |> SF.valves_to_axis(1..3)
      assert_in_delta input, output, 0.01
    end)
  end

  test "valves_to_axis/2 + axis_to_valves/1 = same value" do
    1..100
    |> Enum.each(fn _ ->
      valves = random_valves()

      assert valves
             |> SF.valves_to_axis(1..3)
             |> SF.axis_to_valves() == valves
    end)
  end

  defp number_stream(initial, fun) do
    Stream.resource(
      fn -> initial end,
      fn n ->
        {[n], fun.(n)}
      end,
      fn _ -> :done end
    )
  end

  all_mscv = 3..50 |> Enum.map(&{0, &1})
  all_bypass = 0..80 |> Enum.map(&{&1, 3})
  @all MapSet.new(all_mscv ++ all_bypass)

  defp random_valves do
    {bypass, mscv} = base = Enum.random(@all)

    next =
      [{bypass, mscv + 1}, {bypass, mscv}]
      |> Enum.find(&(&1 in @all))

    has_next = Enum.random(0..2)

    1..3
    |> Enum.map(fn i ->
      case i <= has_next do
        true -> next
        false -> base
      end
    end)
  end
end
