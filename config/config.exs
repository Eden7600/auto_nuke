import Config

config :logger, :console, format: {AutoNuke.LogFormatter, :format}

import_config "#{Mix.env()}.exs"
