defmodule SessionDesk.Protocol do
  @moduledoc "Strict LF framing. Unicode line separators are data, not record boundaries."
  @limit 8 * 1024 * 1024
  def feed(buffer, chunk) do
    parts = :binary.split(buffer <> chunk, "\n", [:global])
    tail = List.last(parts)
    lines = Enum.drop(parts, -1)

    if byte_size(tail) > @limit or Enum.any?(lines, &(byte_size(&1) > @limit)) do
      {:error, :record_too_large}
    else
      records = for line <- lines, line != "", do: Jason.decode(String.trim_trailing(line, "\r"))
      {:ok, records, tail}
    end
  end
end
