defmodule SessionDeskWeb.DeskLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SessionDeskWeb.Endpoint

  setup do
    start_supervised!(
      {SessionDesk.Session,
       id: "main",
       command: {System.find_executable("node"), [Path.expand("priv/demo_agent.mjs")]},
       workspace: File.cwd!()}
    )

    wait_until(fn -> SessionDesk.Session.snapshot().status == :idle end)
    :ok
  end

  test "mounts, sends a prompt and reconnects to the same controller" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Demo mode"
    assert html =~ "Gentle Todo"
    controller = GenServer.whereis(SessionDesk.Session.via("main"))
    view |> form("#composer", message: "Make a plan") |> render_submit()
    wait_until(fn -> SessionDesk.Session.snapshot().status == :working end)
    {:ok, reconnected, _} = live(build_conn(), "/")
    assert controller == GenServer.whereis(SessionDesk.Session.via("main"))
    wait_until(fn -> render(reconnected) =~ "Collect your preference" end)
    assert render(reconnected) =~ "Collect your preference"
    assert render(reconnected) =~ "Which behavior should we verify next?"
    assert render(reconnected) =~ "Needs your input"

    reconnected
    |> element("button[phx-value-choice='Reconnect while working']")
    |> render_click(%{"value" => ""})

    wait_until(fn -> SessionDesk.Session.snapshot().questions == [] end)
    refute render(reconnected) =~ "the answer is invalid"
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
