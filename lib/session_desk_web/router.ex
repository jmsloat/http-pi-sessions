defmodule SessionDeskWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SessionDeskWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  get "/health", SessionDeskWeb.HealthController, :show

  scope "/" do
    pipe_through :browser
    live "/", SessionDeskWeb.DeskLive, :index
  end
end

defmodule SessionDeskWeb.HealthController do
  use Phoenix.Controller, formats: [:json]
  def show(conn, _), do: json(conn, %{status: "ok"})
end

defmodule SessionDeskWeb.ErrorHTML do
  def render(template, _), do: Phoenix.Controller.status_message_from_template(template)
end
