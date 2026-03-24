defmodule AutoNuke.Test.MockAPI do
  def mock_get(key, value) do
    send(self(), {__MODULE__, :mocked, :get, key, "#{value}"})
  end

  def get(key) do
    receive do
      {__MODULE__, :mocked, :get, ^key, value} -> value
    after
      0 -> raise "API `get` call was not mocked: #{inspect(key)}"
    end
  end

  def put(key, value) do
    send(self(), {__MODULE__, :called, :put, key, value})
  end

  def mock_put_value(key) do
    receive do
      {__MODULE__, :called, :put, ^key, value} -> value
    after
      0 -> raise "API `put` call was not received: #{inspect(key)}"
    end
  end
end
