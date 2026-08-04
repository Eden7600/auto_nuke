import Config

config :logger, :console, format: {AutoNuke.LogFormatter, :format}

# Without this, supervisor and child-start crash reports are dropped
# before any handler sees them — a crash-looping operator can take the
# whole OperatorSupervisor down with nothing in tui.log.
config :logger, handle_sasl_reports: true

import_config "#{Mix.env()}.exs"
