import Config

config :nx, :default_backend, EXLA.Backend
config :bumblebee, :default_backend, EXLA.Backend

config :logger, level: :warning
import_config "#{config_env()}.exs"