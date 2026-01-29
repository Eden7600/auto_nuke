defmodule AutoNuke.API do
  defp api_url, do: Application.fetch_env!(:auto_nuke, :api_url)

  defp req_new do
    Req.new(base_url: api_url())
  end

  defp get(key) do
    req_new()
    |> Req.get!(url: "/", params: [variable: key])
    |> then(fn %Req.Response{status: 200, body: body} -> body end)
  end

  def get_string(key), do: get(key)
  def get_integer(key), do: get(key) |> String.to_integer()

  # Handles either `62.3` or just `62`.
  def get_float(key) do
    {float, ""} = get(key) |> Float.parse()
    float
  end

  def put(key, value) do
    req_new()
    |> Req.post!(url: "/", params: [variable: key, value: value], body: "")
  end
end
