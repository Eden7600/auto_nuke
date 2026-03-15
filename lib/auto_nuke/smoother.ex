defmodule AutoNuke.Smoother do
  @enforce_keys [:max]
  defstruct(
    data: :queue.new(),
    size: 0,
    max: nil
  )

  alias __MODULE__
  require Integer

  def new(max_size) when is_integer(max_size) and max_size > 1, do: %Smoother{max: max_size}

  def add(%Smoother{size: size, max: max} = smoother, value)
      when size < max and is_number(value) do
    %Smoother{
      smoother
      | data: :queue.in(value, smoother.data),
        size: size + 1
    }
  end

  def add(%Smoother{size: size, max: max} = smoother, value)
      when size == max and is_number(value) do
    %Smoother{
      smoother
      | data: :queue.in(value, :queue.drop(smoother.data))
    }
  end

  def average(%Smoother{data: data, size: size}) when size > 0 do
    data
    |> :queue.to_list()
    |> Enum.sum()
    |> Kernel./(size)
  end

  def median(%Smoother{data: data, size: size}) when Integer.is_odd(size) and size > 0 do
    data
    |> :queue.to_list()
    |> Enum.sort()
    |> Enum.at(div(size, 2))
  end

  def median(%Smoother{data: data, size: size}) when Integer.is_even(size) and size > 0 do
    [a, b] =
      data
      |> :queue.to_list()
      |> Enum.sort()
      |> Enum.slice(div(size, 2) - 1, 2)

    (a + b) / 2
  end
end
