import Config

config :nx, :default_backend, EXLA.Backend
config :bumblebee, :default_backend, EXLA.Backend

config :logger, level: :info
import_config "#{config_env()}.exs"