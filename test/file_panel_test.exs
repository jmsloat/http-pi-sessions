defmodule SessionDeskWeb.FilePanelTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SessionDesk.{Catalog, Session, State}
  @endpoint SessionDeskWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "desk-panel-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "project")
    File.mkdir_p!(Path.join(workspace, "notes"))

    File.write!(
      Path.join(workspace, "notes/file.html"),
      "<script>alert('never execute')</script>"
    )

    File.write!(Path.join(workspace, "change.txt"), "before\n")

    for args <- [
          ["init", "-q"],
          ["config", "user.email", "test@example.com"],
          ["config", "user.name", "Test"],
          ["add", "."],
          ["commit", "-qm", "baseline"]
        ],
        do: System.cmd("git", args, cd: workspace)

    File.write!(Path.join(workspace, "change.txt"), "after\n")
    start_supervised!({Catalog, root: root, workspace: workspace, mode: "demo"})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace}
  end

  test "browses and escapes source, renders diffs and refreshes without launching Pi", %{
    workspace: workspace
  } do
    {:ok, view, _} = live(build_conn(), "/")
    view |> element("#files-tab") |> render_click()
    render_async(view)
    assert has_element?(view, ".change-row", "change.txt")
    view |> element("button[phx-click=diff][phx-value-path='change.txt']") |> render_click()
    render_async(view)
    assert has_element?(view, ".diff-preview .added", "+after")
    assert has_element?(view, ".diff-preview .removed", "-before")
    view |> element(".file-entry[phx-value-path=notes]") |> render_click()
    render_async(view)
    view |> element(".file-entry[phx-value-path='notes/file.html']") |> render_click()
    render_async(view)
    assert has_element?(view, ".source-preview", "<script>alert('never execute')</script>")
    refute has_element?(view, "#file-preview script")
    File.write!(Path.join(workspace, "notes/file.html"), "updated outside the app")
    view |> element("#refresh-files") |> render_click()
    render_async(view)
    assert has_element?(view, ".source-preview", "updated outside the app")
    assert Registry.lookup(SessionDesk.Registry, "demo-main") == []
    File.rm!(Path.join(workspace, "notes/file.html"))
    view |> element("#refresh-files") |> render_click()
    render_async(view)
    assert has_element?(view, "#file-preview [role=alert]", "no longer exists")
    view |> element("button[aria-label='Close preview']") |> render_click()
    refute has_element?(view, "#file-preview")
  end

  test "switching workspace sessions resets preview and folder state", %{root: root} do
    other = Path.join(root, "other")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "different.txt"), "other workspace")
    {:ok, workspace_id} = Catalog.add_workspace("Other", other)
    {:ok, session_id} = Catalog.create_session(workspace_id, "Other session")
    {:ok, view, _} = live(build_conn(), "/sessions/demo-main")
    view |> element("#files-tab") |> render_click()
    render_async(view)
    view |> element(".file-entry[phx-value-path=notes]") |> render_click()
    render_async(view)
    view |> element(".file-entry[phx-value-path='notes/file.html']") |> render_click()
    render_async(view)
    render_patch(view, "/sessions/" <> session_id)
    render_async(view)
    assert has_element?(view, ".file-entry", "different.txt")
    refute has_element?(view, "#file-preview")
    refute has_element?(view, ".file-entry", "file.html")
    assert has_element?(view, ".file-notice", "not a Git repository")
    view |> element(".file-entry[phx-value-path='different.txt']") |> render_click()
    render_async(view)
    assert has_element?(view, ".source-preview", "other workspace")
  end

  test "finishing an agent turn refreshes the selected file", %{workspace: workspace} do
    {:ok, controller} = Catalog.activate("demo-main")
    wait_until(fn -> Session.snapshot("demo-main").status == :idle end)
    {:ok, view, _} = live(build_conn(), "/sessions/demo-main")
    view |> element("#files-tab") |> render_click()
    render_async(view)
    view |> element(".file-entry[phx-value-path='change.txt']") |> render_click()
    render_async(view)
    state = State.apply(Session.snapshot("demo-main"), %{"type" => "agent_start"})
    send(view.pid, {:session, "demo-main", controller, state})
    render(view)
    File.write!(Path.join(workspace, "change.txt"), "agent wrote this")

    send(
      view.pid,
      {:session, "demo-main", controller, %{state | status: :idle, revision: state.revision + 1}}
    )

    render(view)
    render_async(view)
    assert has_element?(view, ".source-preview", "agent wrote this")
  end

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_, 0), do: flunk("Timed out")

  defp wait_until(fun, tries) do
    unless fun.() do
      Process.sleep(30)
      wait_until(fun, tries - 1)
    end
  end
end
