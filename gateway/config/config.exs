import Config

# shared defaults; dev.exs, test.exs and runtime.exs (prod) fill in the rest
config :gateway,
  clock: Gateway.Clock.System,
  # unknown ntp status counts as unsynced, which locks the rmm channel
  assume_clock_synced: false,
  default_mode: :monitor,
  tick_ms: 15_000,
  events_capacity: 10_000

import_config "#{config_env()}.exs"
