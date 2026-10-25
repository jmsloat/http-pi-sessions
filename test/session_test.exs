defmodule SessionDesk.SessionTest do
  use ExUnit.Case, async: false
  alias SessionDesk.Session

  setup do
    id = "test-#{System.unique_integer([:positive])}"
    fixture = Path.expand("priv/demo_agent.mjs")

    pid =
      start_supervised!(
        {Session,
         id: id, command: {System.find_executable("node"), [fixture]}, workspace: File.cwd!()}
      )

    eventually(fn -> Session.snapshot(id).status == :idle end)
    %{id: id, pid: pid}
  end

  test "run outlives a disconnected subscriber and a new subscriber sees the pending question", %{
    id: id,
    pid: pid
  } do
    subscriber =
      spawn(fn ->
        Session.subscribe(id)

        receive do
          :stop -> :ok
        end
      end)

    assert :ok = Session.command({:prompt, "Make a plan"}, id)
    send(subscriber, :stop)
    eventually(fn -> Session.snapshot(id).status == :waiting end)
    assert Process.alive?(pid)
    assert length(Session.snapshot(id).tasks) == 3
    Session.subscribe(id)
    question = hd(Session.snapshot(id).questions)
    assert {:error, _} = Session.command({:answer, question["id"], %{"value" => "invented"}}, id)

    assert :ok =
             Session.command({:answer, question["id"], %{"value" => hd(question["options"])}}, id)

    assert {:error, _} =
             Session.command({:answer, question["id"], %{"value" => hd(question["options"])}}, id)

    eventually(fn -> Session.snapshot(id).status == :idle end)
    assert Enum.all?(Session.snapshot(id).tasks, &(&1["status"] == "done"))
  end

  test "abort settles the run and does not replay its prompt", %{id: id} do
    assert :ok = Session.command({:prompt, "Start"}, id)
    assert {:error, _} = Session.command({:prompt, "Duplicate"}, id)
    assert :ok = Session.command(:abort, id)
    eventually(fn -> Session.snapshot(id).status == :idle end)
    assert length(Enum.filter(Session.snapshot(id).messages, &(&1.role == "user"))) == 1
  end

  defp eventually(fun, tries \\ 250)
  defp eventually(_, 0), do: flunk("Condition did not become true")

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(40)
          eventually(fun, tries - 1)
        )
  end
end
