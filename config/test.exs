import Config

config :auto_nuke,
  testing: true,
  start: false,
  api_backend: AutoNuke.Test.MockAPI

config :logger, level: :warning
