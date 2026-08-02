defmodule AutoNuke.API.Web do
  use Memoize

  @config_key :api_web_config

  def set_config(config), do: Process.put(@config_key, config)
  defp get_config, do: Process.get(@config_key, :default)

  defp api_url do
    case System.fetch_env("NUKE_URL") do
      {:ok, url} -> url
      :error -> Application.fetch_env!(:auto_nuke, :api_url)
    end
  end

  defp req_new, do: get_config() |> req_new()

  defp req_new(:default) do
    Req.new(
      base_url: api_url(),
      max_retries: 2,
      retry_delay: fn _ -> 500 end,
      connect_options: [timeout: 500]
    )
  end

  defp req_new(:fast) do
    Req.new(
      base_url: api_url(),
      max_retries: 2,
      retry_delay: fn _ -> 100 end,
      connect_options: [timeout: 100]
    )
  end

  defp req_new(:ping) do
    Req.new(
      base_url: api_url(),
      max_retries: 4,
      retry_delay: fn _ -> 1000 end,
      retry_log_level: false,
      connect_options: [timeout: 1000]
    )
  end

  def get(key) do
    req_new()
    |> Req.get!(url: "/", params: [variable: key])
    |> then(fn
      %Req.Response{status: 200, body: body} -> body
      %Req.Response{} = response -> raise_api_error!("read", key, response)
    end)
  end

  def put(key, value) do
    put_with_reply(key, value)
    :ok
  end

  # Some writes answer with useful text (e.g. which pump a drill jammed).
  def put_with_reply(key, value) do
    req_new()
    |> Req.post!(url: "/", params: [variable: key, value: value], body: "")
    |> then(fn
      %Req.Response{status: 200, body: body} -> {:ok, body}
      %Req.Response{} = response -> raise_api_error!("write #{inspect(value)} to", key, response)
    end)
  end

  defp raise_api_error!(action, key, %Req.Response{status: status, body: body}) do
    raise "Nucleares API failed to #{action} #{key}: HTTP #{status}, #{inspect(body)}"
  end

  alias Req.TransportError, as: RTE

  def ping do
    req_new(:ping)
    |> Req.get(url: "/", params: [variable: "CORE_TEMP"])
    |> then(fn
      {:ok, %Req.Response{status: 200}} -> :ok
      {:error, %RTE{reason: :timeout}} -> {:error, "Timeout."}
      {:error, %RTE{reason: :ehostunreach}} -> {:error, "Host is unreachable."}
      {:error, %RTE{reason: :ehostdown}} -> {:error, "Host is down."}
      {:error, %RTE{reason: :econnrefused}} -> {:error, "Connection refused."}
    end)
  end
end
