defmodule AutoNuke.API do
  @backend Application.compile_env(:auto_nuke, :api_backend, AutoNuke.API.Web)

  use Memoize

  defp get(key), do: @backend.get(key)
  defdelegate put(key, value), to: @backend

  defmemo get_string(key) do
    get(key)
  end

  defmemo get_integer(key) do
    get(key)
    |> to_integer()
  end

  defmemo get_float(key) do
    get(key)
    |> to_float()
  end

  defmemo get_integer_or_nil(key, default \\ nil) do
    get(key)
    |> or_nil(&to_integer/1, default)
  end

  defmemo get_float_or_nil(key, default \\ nil) do
    get(key)
    |> or_nil(&to_float/1, default)
  end

  defmemo get_json(key) do
    get(key)
    |> Jason.decode!()
  end

  defmemo get_boolean(key) do
    case get(key) do
      "True" -> true
      "False" -> false
    end
  end

  defp or_nil("null", _, default), do: default
  defp or_nil(str, fun, _), do: fun.(str)

  defp to_integer(str), do: String.to_integer(str)

  # Handles either `62.3` or just `62`.
  # Games running in locales with a decimal comma send `62,3` instead.
  defp to_float(str) do
    {float, ""} =
      str
      |> String.replace(",", ".")
      |> Float.parse()

    float
  end
end
