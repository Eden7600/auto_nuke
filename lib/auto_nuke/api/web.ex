defmodule AutoNuke.API.Web do
  defp api_url do
    case System.fetch_env("NUKE_URL") do
      {:ok, url} -> url
      :error -> Application.fetch_env!(:auto_nuke, :api_url)
    end
  end

  defp req_new do
    Req.new(base_url: api_url())
  end

  def get(key) do
    req_new()
    |> Req.get!(url: "/", params: [variable: key])
    |> then(fn %Req.Response{status: 200, body: body} -> body end)
  end

  def put(key, value) do
    req_new()
    |> Req.post!(url: "/", params: [variable: key, value: value], body: "")
    |> then(fn %{status: 200} -> :ok end)
  end
end
