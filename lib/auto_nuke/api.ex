defmodule AutoNuke.API do
  @backend Application.compile_env(:auto_nuke, :api_backend, AutoNuke.API.Web)

  defp get(key), do: @backend.get(key)
  defdelegate put(key, value), to: @backend

  def get_string(key), do: get(key)
  def get_integer(key), do: get(key) |> to_integer()
  def get_float(key), do: get(key) |> to_float()
  def get_integer_or_nil(key, default \\ nil), do: get(key) |> or_nil(&to_integer/1, default)
  def get_float_or_nil(key, default \\ nil), do: get(key) |> or_nil(&to_float/1, default)
  def get_json(key), do: get(key) |> Jason.decode!()

  defp or_nil("null", _, default), do: default
  defp or_nil(str, fun, _), do: fun.(str)

  defp to_integer(str), do: String.to_integer(str)

  # Handles either `62.3` or just `62`.
  defp to_float(str) do
    {float, ""} = Float.parse(str)
    float
  end

  def get_boolean(key) do
    case get(key) do
      "True" -> true
      "False" -> false
    end
  end
end
