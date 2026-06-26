defmodule AutoNuke.Smoother do
  @enforce_keys [:max]
  defstruct(
    data: :queue.new(),
    size: 0,
    max: nil
  )

  alias __MODULE__
  require Integer
  alias Scholar.Linear.LinearRegression

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
    |> Statistex.average()
  end

  def median(%Smoother{data: data, size: size}) when size > 0 do
    data
    |> :queue.to_list()
    |> Statistex.median()
  end

  def rate_of_change(%Smoother{size: 1}), do: 0.0

  def rate_of_change(%Smoother{data: data, size: max, max: max}) do
    {:value, first} = :queue.peek(data)
    {:value, last} = :queue.peek_r(data)
    last - first
  end

  def rate_of_change(%Smoother{data: data, size: size, max: max}) when size > 0 do
    {:value, first} = :queue.peek(data)
    {:value, last} = :queue.peek_r(data)
    scale_factor = (size - 1) / (max - 1)
    (last - first) / scale_factor
  end

  # Guess where reading will be in `from_now` ticks.
  def extrapolate(%Smoother{data: data, size: size}, from_now) when size > 0 do
    # Last data point will be X = 0
    xs = -(size - 1)..0 |> Enum.map(&[&1]) |> Nx.tensor()
    ys = :queue.to_list(data) |> Enum.map(&[&1]) |> Nx.tensor()
    # Treat the latest value as having 3x the predictive power of the first.
    weights = 1..size |> Enum.map(&(1.0 + 2 * &1 / size))

    # Calculate value at X = from_now
    LinearRegression.fit(xs, ys, sample_weights: weights)
    |> LinearRegression.predict(Nx.tensor([from_now]))
    |> Nx.to_number()
  end
end
