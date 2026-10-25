defmodule SessionDeskWeb.Markdown do
  @moduledoc "Sanitized Markdown for agent output, including fenced code blocks."
  def render(text) do
    text
    |> MDEx.to_html!()
    |> HtmlSanitizeEx.markdown_html()
    |> Phoenix.HTML.raw()
  end
end
