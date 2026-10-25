import Config

# Minimal container environments may omit SHELL; erlexec requires it.
System.put_env("SHELL", System.get_env("SHELL", "/bin/sh"))

if System.get_env("PHX_SERVER") == "true" do
  config :session_desk, SessionDeskWeb.Endpoint, server: true
end

if System.get_env("ERLEXEC_ROOT") == "1" do
  config :erlexec, root: true, user: ~c"root", limit_users: [~c"root"]
end

data_dir = Path.expand(System.get_env("DATA_DIR", "data"))
workspace = Path.expand(System.get_env("WORKSPACE", "."))
mode = System.get_env("SESSION_DESK_MODE", "demo")
unless mode in ["demo", "live"], do: raise("SESSION_DESK_MODE must be demo or live")
origin = System.get_env("APP_ORIGIN", "http://localhost:4000")
uri = URI.parse(origin)
secret = System.get_env("SECRET_KEY_BASE")

if config_env() == :prod and (is_nil(secret) or byte_size(secret) < 64),
  do: raise("SECRET_KEY_BASE must contain at least 64 bytes in production")

config :session_desk,
  mode: mode,
  workspace: workspace,
  data_dir: data_dir,
  pi_executable: System.get_env("PI_EXECUTABLE", "pi"),
  pi_args: Jason.decode!(System.get_env("PI_ARGS_JSON", "[]")),
  pi_home: System.get_env("PI_CODING_AGENT_DIR")

config :session_desk, SessionDeskWeb.Endpoint,
  http: [
    ip:
      if(System.get_env("BIND", "127.0.0.1") == "0.0.0.0", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}),
    port: String.to_integer(System.get_env("PORT", "4000"))
  ],
  url: [scheme: uri.scheme, host: uri.host, port: uri.port],
  check_origin: [origin],
  secret_key_base: secret || String.duplicate("local-prototype-only-", 4)
