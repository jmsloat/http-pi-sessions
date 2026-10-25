defmodule SessionDesk.MixProject do
  use Mix.Project
  def cli, do: [preferred_envs: [check: :test]]

  def project do
    [
      app: :session_desk,
      version: "0.3.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [setup: ["deps.get", "assets.copy"], check: ["format --check-formatted", "test"]]
    ]
  end

  def application,
    do: [mod: {SessionDesk.Application, []}, extra_applications: [:logger, :runtime_tools]]

  defp deps do
    [
      {:phoenix, "~> 1.7.21"},
      {:phoenix_live_view, "~> 1.0.18"},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:erlexec, "~> 2.5.0"},
      {:exqlite, "~> 0.43.0"},
      {:mdex, "~> 0.14.3"},
      {:html_sanitize_ex, "~> 1.5"},
      {:floki, "~> 0.36.0", only: :test}
    ]
  end
end
