import Config

config :session_desk, SessionDeskWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: SessionDeskWeb.ErrorHTML], layout: false],
  pubsub_server: SessionDesk.PubSub,
  live_view: [signing_salt: "session-desk"],
  secret_key_base: String.duplicate("local-prototype-only-", 4)

config :phoenix, :json_library, Jason
config :session_desk, start_session: config_env() != :test
config :logger, :console, format: "$time $level $message\n"
