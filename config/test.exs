import Config

config :auto_nuke,
  start: false,
  api_backend: AutoNuke.Test.MockAPI

config :logger, level: :warning
