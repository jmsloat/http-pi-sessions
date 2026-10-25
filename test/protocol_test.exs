defmodule SessionDesk.ProtocolTest do
  use ExUnit.Case, async: true
  alias SessionDesk.Protocol

  test "frames partial records, CRLF and Unicode separators without splitting JSON" do
    {:ok, [], buffer} = Protocol.feed("", "{\"text\":\"a\u2028")

    assert {:ok, [{:ok, %{"text" => "a\u2028b"}}, {:ok, %{"x" => 2}}], "tail"} =
             Protocol.feed(buffer, "b\"}\r\n{\"x\":2}\ntail")
  end

  test "rejects oversized records even if they end in a newline" do
    assert {:error, :record_too_large} =
             Protocol.feed("", String.duplicate("x", 8 * 1024 * 1024 + 1) <> "\n")
  end
end
