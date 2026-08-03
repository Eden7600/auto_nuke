defmodule AutoNuke.Settings do
  @moduledoc """
  Tiny persistent key-value settings, stored as JSON next to the project
  (`auto_nuke.settings.json`). For knobs the user flips at runtime that
  must survive restarts — not for anything derivable from config files.
  """

  @default_file "auto_nuke.settings.json"

  def get(key, default) do
    case File.read(file()) do
      {:ok, body} -> body |> Jason.decode!() |> Map.get(key, default)
      {:error, _} -> default
    end
  rescue
    # A corrupt settings file must never take anything down.
    _ -> default
  end

  def put(key, value) do
    settings =
      case File.read(file()) do
        {:ok, body} -> Jason.decode!(body)
        {:error, _} -> %{}
      end
      |> Map.put(key, value)

    File.write(file(), Jason.encode!(settings, pretty: true))
  rescue
    _ -> File.write(file(), Jason.encode!(%{key => value}, pretty: true))
  end

  defp file, do: Application.get_env(:auto_nuke, :settings_file, @default_file)
end
