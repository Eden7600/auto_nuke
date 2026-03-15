defmodule AutoNuke.Smoother do
  @enforce_keys [:max]
  defstruct(
    data: :queue.new(),
    size: 0,
    max: nil
  )

  alias __MODULE__

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

  def average(%Smoother{data: data, size: size}) do
    data
    |> :queue.to_list()
    |> Enum.sum()
    |> Kernel./(size)
  end
end
