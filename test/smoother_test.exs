defmodule AutoNuke.SmootherTest do
  use ExUnit.Case
  alias AutoNuke.Smoother

  test "Smoother.add/2 adds data values" do
    smoother =
      Smoother.new(5)
      |> Smoother.add(1)
      |> Smoother.add(2)
      |> Smoother.add(3)

    assert smoother.size == 3
    assert :queue.to_list(smoother.data) == [1, 2, 3]
  end

  test "Smoother.add/2 deletes old data after size reached" do
    smoother =
      Smoother.new(5)
      |> Smoother.add(1)
      |> Smoother.add(2)
      |> Smoother.add(3)
      |> Smoother.add(4)
      |> Smoother.add(5)
      |> Smoother.add(6)
      |> Smoother.add(7)

    assert smoother.size == 5
    assert :queue.to_list(smoother.data) == [3, 4, 5, 6, 7]
  end

  test "Smoother.average/1 returns average of stored data" do
    smoother = Smoother.new(5) |> Smoother.add(5)
    # Only one entry, so that's the average.
    assert Smoother.average(smoother) == 5

    smoother = smoother |> Smoother.add(10.3)
    # Total 15.3, so average is 7.65.
    assert Smoother.average(smoother) == 7.65

    smoother =
      smoother
      |> Smoother.add(18.2)
      |> Smoother.add(7.5)
      |> Smoother.add(9)

    # Total 50, so average is 10.
    assert Smoother.average(smoother) == 10

    # Remove 5, add 19, total 64, average 12.8.
    smoother = smoother |> Smoother.add(19)
    assert Smoother.average(smoother) == 12.8
  end
end
