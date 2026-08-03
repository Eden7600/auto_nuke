import Config

config :auto_nuke,
  testing: true,
  start: false,
  api_backend: AutoNuke.Test.MockAPI,
  settings_file: "tmp/test.settings.json"

config :logger, :console, format: "$time $metadata[$level] $message\n"
config :logger, level: :warning

config :memoize, cache_strategy: AutoNuke.Test.NullCacheStrategy
