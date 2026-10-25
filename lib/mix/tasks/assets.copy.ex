defmodule Mix.Tasks.Assets.Copy do
  use Mix.Task
  @shortdoc "Copy Phoenix browser bundles locally; no npm build or CDN"
  def run(_) do
    File.mkdir_p!("priv/static/vendor")

    for {source, target} <- [
          {"deps/phoenix/priv/static/phoenix.js", "phoenix.js"},
          {"deps/phoenix_live_view/priv/static/phoenix_live_view.js", "phoenix_live_view.js"}
        ],
        do: File.cp!(source, "priv/static/vendor/" <> target)
  end
end
