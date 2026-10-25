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

  test "saved and resumed history hides thinking, tool-only and whitespace turns but keeps replies and errors" do
    hidden = [
      %{"type" => "thinking", "thinking" => "Internal reasoning"},
      %{"type" => "toolCall", "id" => "a", "name" => "read"},
      %{"type" => "toolCall", "id" => "b", "name" => "bash"}
    ]

    history = [
      %{"role" => "user", "content" => "Review the project"},
      %{"role" => "assistant", "content" => hidden},
      %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => " \n\t "}],
        "errorMessage" => ""
      },
      %{
        "role" => "assistant",
        "content" => hidden ++ [%{"type" => "text", "text" => "Here is the reply"}]
      },
      %{"role" => "assistant", "content" => [], "errorMessage" => "Provider unavailable"}
    ]

    File.write!(SessionDesk.Catalog.get("demo-main").file, Jason.encode!(history))
    {:ok, view, _} = live(build_conn(), "/")
    assert_visible_history(view)
    view |> element("#resume-session") |> render_click()
    wait_until(fn -> has_element?(view, ".message.assistant .markdown", "Here is the reply") end)
    assert_visible_history(view)
    {:ok, reconnected, _} = live(build_conn(), "/sessions/demo-main")
    assert_visible_history(reconnected)
  end

  test "an active empty turn stays hidden until text arrives and its later text is preserved" do
    alias SessionDesk.{Catalog, Session, State}
    {:ok, controller} = Catalog.activate("demo-main")
    wait_until(fn -> Session.snapshot("demo-main").status == :idle end)
    {:ok, view, _} = live(build_conn(), "/sessions/demo-main")

    state =
      Session.snapshot("demo-main")
      |> State.apply(%{"type" => "agent_start"})
      |> State.apply(%{
        "type" => "message_start",
        "message" => %{"role" => "assistant", "content" => []}
      })

    send(view.pid, {:session, "demo-main", controller, state})
    refute has_element?(view, ".message.assistant")
    assert has_element?(view, "#session-status", "Working")

    state =
      State.apply(state, %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => "Reasoning"}
      })

    send(view.pid, {:session, "demo-main", controller, state})
    refute has_element?(view, ".message.assistant")

    state =
      State.apply(state, %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Visible answer"}
      })

    send(view.pid, {:session, "demo-main", controller, state})
    assert has_element?(view, ".message.assistant .markdown", "Visible answer")

    state =
      State.apply(state, %{
        "type" => "message_end",
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "thinking", "thinking" => "Reasoning"},
            %{"type" => "text", "text" => "Visible answer"}
          ]
        }
      })

    send(view.pid, {:session, "demo-main", controller, state})
    assert has_element?(view, ".message.assistant .markdown", "Visible answer")
    assert length(Floki.find(Floki.parse_document!(render(view)), ".message.assistant")) == 1
  end

  defp assert_visible_history(view) do
    html = render(view)
    assert length(Floki.find(Floki.parse_document!(html), ".message.assistant")) == 2
    assert has_element?(view, ".message.assistant .markdown", "Here is the reply")
    assert has_element?(view, ".message.assistant .error", "Provider unavailable")
    assert length(Floki.find(Floki.parse_document!(html), ".message.assistant .markdown")) == 1
    refute html =~ "Internal reasoning"
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
