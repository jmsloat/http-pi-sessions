defmodule SessionDesk.StateTest do
  use ExUnit.Case, async: true
  alias SessionDesk.State

  defp snapshot(status),
    do: %{
      "gentleTodo" => %{
        "tasks" => [%{"id" => 7, "title" => "Keep exact IDs", "status" => status}],
        "updatedTurn" => 1
      }
    }

  test "non-text blocks do not create separator-only text or pad mixed content" do
    hidden = [
      %{"type" => "thinking", "thinking" => "Internal reasoning"},
      %{"type" => "toolCall", "id" => "a", "name" => "read"},
      %{"type" => "toolCall", "id" => "b", "name" => "bash"}
    ]

    assert State.text(hidden) == ""

    assert State.text(hidden ++ [%{"type" => "text", "text" => "Visible reply"}] ++ hidden) ==
             "Visible reply"

    assert State.text([
             %{"type" => "text", "text" => "First"},
             hd(hidden),
             %{"type" => "text", "text" => "Second"}
           ]) == "First\nSecond"
  end

  test "projects Gentle snapshots, including failed mutations that return unchanged state" do
    s =
      State.apply(%State{}, %{
        "type" => "tool_execution_end",
        "result" => %{"details" => snapshot("blocked")}
      })

    assert [%{"id" => 7, "status" => "blocked"}] = s.tasks

    s =
      State.apply(s, %{
        "type" => "extension_ui_request",
        "method" => "setWidget",
        "widgetKey" => "gentle-todo"
      })

    assert s.tasks == []
  end

  test "restores tasks from history, but hides finished lists on resume" do
    history = [
      %{"role" => "user", "content" => "hello"},
      %{"role" => "toolResult", "details" => snapshot("pending")}
    ]

    assert [%{"status" => "pending"}] = State.restore(%State{}, history).tasks

    assert [] =
             State.restore(
               %State{},
               history ++ [%{"role" => "toolResult", "details" => snapshot("done")}]
             ).tasks
  end

  test "streaming updates replace the active message rather than duplicating it" do
    s =
      State.apply(%State{}, %{
        "type" => "message_start",
        "message" => %{"role" => "assistant", "content" => []}
      })

    s =
      State.apply(s, %{
        "type" => "message_update",
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hello"}]
        }
      })

    assert [%{text: "Hello"}] = s.messages
  end

  test "questions survive snapshots and clear when agent settles" do
    s =
      State.apply(%State{}, %{
        "type" => "extension_ui_request",
        "id" => "q",
        "method" => "confirm",
        "title" => "Continue?"
      })

    assert s.status == :waiting
    assert length(s.questions) == 1
    assert State.apply(s, %{"type" => "agent_settled"}).questions == []
  end

  test "current Pi text deltas arrive without a message snapshot" do
    s =
      State.apply(%State{}, %{
        "type" => "message_start",
        "message" => %{"role" => "assistant", "content" => []}
      })

    s =
      State.apply(s, %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello "}
      })

    s =
      State.apply(s, %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "world"}
      })

    assert [%{text: "Hello world"}] = s.messages
    assert State.apply(s, %{"type" => "agent_end"}).status == :settling
  end
end
