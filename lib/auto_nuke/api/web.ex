defmodule AutoNuke.API.Web do
  use Memoize

  def set_api_config(c), do: Process.put(:api_config, c)

  defp api_url do
    case System.fetch_env("NUKE_URL") do
      {:ok, url} -> url
      :error -> Application.fetch_env!(:auto_nuke, :api_url)
    end
  end

  defp req_new do
    Process.get(:api_config, :default)
    |> req_new()
  end

  defp req_new(:init) do
    Req.new(
      base_url: api_url(),
      max_retries: 4,
      retry_delay: fn _ -> 1000 end,
      retry_log_level: false,
      connect_options: [timeout: 1000]
    )
  end

  defp req_new(:default) do
    Req.new(base_url: api_url())
  end

  defp req_new(:fast) do
    Req.new(
      base_url: api_url(),
      max_retries: 1,
      retry_delay: fn _ -> 100 end,
      connect_options: [timeout: 100]
    )
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
