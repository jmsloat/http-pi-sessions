defmodule SessionDesk.HistoryTest do
  use ExUnit.Case, async: true
  alias SessionDesk.History

  test "follows the selected branch rather than merging abandoned conversation branches" do
    entries = [
      %{type: "message", id: "a", parentId: nil, message: %{role: "user", content: "Root"}},
      %{
        type: "message",
        id: "b",
        parentId: "a",
        message: %{role: "assistant", content: "Abandoned"}
      },
      %{
        type: "message",
        id: "c",
        parentId: "a",
        message: %{role: "assistant", content: "Current"}
      }
    ]

    bytes = Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n{\"partial\":"
    assert {:ok, messages} = History.messages(bytes, "live")
    assert Enum.map(messages, & &1["content"]) == ["Root", "Current"]
  end

  test "cyclic malformed history does not loop" do
    bytes =
      Jason.encode!(%{
        id: "a",
        parentId: "a",
        type: "message",
        message: %{role: "user", content: "Once"}
      })

    assert {:ok, [_]} = History.messages(bytes, "live")
  end
end
