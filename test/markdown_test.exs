defmodule SessionDeskWeb.MarkdownTest do
  use ExUnit.Case, async: true

  test "renders code and formatting while stripping executable HTML and dangerous links" do
    html =
      SessionDeskWeb.Markdown.render(
        "# Heading\n\n**bold**\n\n```elixir\nIO.puts(\"<hello>\")\n```\n\n<script>alert(1)</script>\n\n[bad](javascript:alert%281%29)\n\n<img src=x onerror=alert(1)>"
      )
      |> Phoenix.HTML.safe_to_string()

    assert html =~ "<h1>Heading</h1>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<pre>"
    assert html =~ "&lt;hello&gt;"
    refute html =~ "<script"
    refute html =~ "javascript:"
    refute html =~ "onerror="
  end
end
