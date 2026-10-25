defmodule SessionDesk.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: SessionDesk.PubSub},
      {Registry, keys: :unique, name: SessionDesk.Registry},
      {DynamicSupervisor, name: SessionDesk.SessionSupervisor, strategy: :one_for_one},
      SessionDeskWeb.Endpoint
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: SessionDesk.Supervisor) do
      if Application.get_env(:session_desk, :start_session),
        do: SessionDesk.Session.start_default()

      {:ok, pid}
    end
  end

  def config_change(changed, _new, removed),
    do: SessionDeskWeb.Endpoint.config_change(changed, removed)
end
