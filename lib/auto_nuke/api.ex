defmodule AutoNuke.API do
  defp api_url do
    case System.fetch_env("NUKE_URL") do
      {:ok, url} -> url
      :error -> Application.fetch_env!(:auto_nuke, :api_url)
    end
  end

  defp req_new do
    Req.new(base_url: api_url())
  end

  defp get(key) do
    req_new()
    |> Req.get!(url: "/", params: [variable: key])
    |> then(fn %Req.Response{status: 200, body: body} -> body end)
  end

  def get_string(key), do: get(key)
  def get_integer(key), do: get(key) |> to_integer()
  def get_float(key), do: get(key) |> to_float()
  def get_integer_or_nil(key, default \\ nil), do: get(key) |> or_nil(&to_integer/1, default)
  def get_float_or_nil(key, default \\ nil), do: get(key) |> or_nil(&to_float/1, default)
  def get_json(key), do: get(key) |> Jason.decode!()

  def or_nil("null", _, default), do: default
  def or_nil(str, fun, _), do: fun.(str)

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

  def put(key, value) do
    req_new()
    |> Req.post!(url: "/", params: [variable: key, value: value], body: "")
    |> then(fn %{status: 200} -> :ok end)
  end
end
