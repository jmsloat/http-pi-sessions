defmodule SessionDeskWeb.DeskLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SessionDeskWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "desk-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    start_supervised!({SessionDesk.Catalog, root: root, workspace: root, mode: "demo"})
    on_exit(fn -> File.rm_rf!(root) end)
    :ok
  end

  test "mounts, sends a prompt and reconnects to the same controller" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Demo mode"
    assert html =~ "Gentle Todo"
    assert Registry.lookup(SessionDesk.Registry, "demo-main") == []
    view |> element("#resume-session") |> render_click()
    wait_until(fn -> SessionDesk.Session.snapshot("demo-main").status == :idle end)
    controller = GenServer.whereis(SessionDesk.Session.via("demo-main"))
    view |> form("#composer", message: "Make a plan") |> render_submit()
    wait_until(fn -> SessionDesk.Session.snapshot("demo-main").status == :working end)
    {:ok, reconnected, _} = live(build_conn(), "/")
    assert controller == GenServer.whereis(SessionDesk.Session.via("demo-main"))
    wait_until(fn -> render(reconnected) =~ "Collect your preference" end)
    assert render(reconnected) =~ "Collect your preference"
    assert render(reconnected) =~ "Which behavior should we verify next?"
    assert render(reconnected) =~ "Needs your input"

    reconnected
    |> element("button[phx-value-choice='Reconnect while working']")
    |> render_click(%{"value" => ""})

    wait_until(fn -> SessionDesk.Session.snapshot("demo-main").questions == [] end)
    refute render(reconnected) =~ "the answer is invalid"
  end

  test "creates, renames, archives and restores sessions without launching an agent" do
    {:ok, view, _} = live(build_conn(), "/")
    view |> form("#new-session", title: "Another task") |> render_submit()
    record = Enum.find(SessionDesk.Catalog.list().sessions, &(&1.title == "Another task"))
    assert_patch(view, "/sessions/" <> record.id)
    assert Registry.lookup(SessionDesk.Registry, record.id) == []
    view |> form("#rename-session", title: "Renamed task") |> render_submit()
    assert SessionDesk.Catalog.get(record.id).title == "Renamed task"
    view |> element("button[phx-click=archive]") |> render_click()
    assert SessionDesk.Catalog.get(record.id).archived
    assert render(view) =~ "Restore session"
    refute has_element?(view, "#resume-session")
    view |> element("button[phx-click=archive]") |> render_click()
    refute SessionDesk.Catalog.get(record.id).archived
    assert has_element?(view, "#resume-session")
  end

  test "model controls update Pi and other tabs; stale events cannot leak across sessions" do
    {:ok, view, _} = live(build_conn(), "/")
    {:ok, other_tab, _} = live(build_conn(), "/")
    view |> element("#resume-session") |> render_click()
    wait_until(fn -> has_element?(view, "#model-select") end)

    view
    |> form("#model-settings", model: Jason.encode!(["demo", "scripted-fast"]))
    |> render_submit()

    wait_until(fn -> SessionDesk.Session.snapshot("demo-main").model == "scripted-fast" end)

    wait_until(fn ->
      has_element?(other_tab, "#model-select option[selected]", "Scripted fast")
    end)

    view |> element("button[phx-click=suspend]") |> render_click()
    wait_until(fn -> has_element?(other_tab, "#resume-session") end)
    other_tab |> element("#resume-session") |> render_click()
    wait_until(fn -> has_element?(view, "#model-select") end)
    assert SessionDesk.Session.snapshot("demo-main").model == "scripted-fast"

    send(
      view.pid,
      {:session, "another-session", self(), %SessionDesk.State{revision: 9999, model: "wrong"}}
    )

    refute render(view) =~ "wrong"
  end

  defp wait_until(fun, tries \\ 250)
  defp wait_until(_, 0), do: flunk("Timed out")

  defp wait_until(fun, tries),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(40)
            wait_until(fun, tries - 1)
          )
      )
end
