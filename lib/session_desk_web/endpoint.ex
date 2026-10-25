defmodule SessionDeskWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :session_desk

  @session_options [
    store: :cookie,
    key: "_session_desk",
    signing_salt: "desk-cookie",
    same_site: "Lax"
  ]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]
  plug Plug.Static, at: "/", from: :session_desk, gzip: false, only: ~w(app.css app.js vendor)
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SessionDeskWeb.Router
end
