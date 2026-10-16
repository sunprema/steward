import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :steward, Steward.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "steward_control_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :steward, StewardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "PckE6kwm/kW7mOOig0Bg4Pe8MRUqCi8deko++Pn8j5lpL7vTHWzdKlENCGMtn2rc",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests start branch processes explicitly; a boot sweep at app start would read
# the database outside any sandbox checkout, and the heartbeat flusher writes only
# when a test calls `HeartbeatFlusher.flush/0`.
config :steward, Steward.Coordinator, boot_sweep: false, heartbeat_flush_ms: :infinity

# Tests start their own Session listener on a free port.
config :steward, StewardWeb.Plane, start_server: false, identity: :header

# Jobs run only when a test drains them (`AshOban.Test`, `Oban.Testing`).
config :steward, Oban, testing: :manual
