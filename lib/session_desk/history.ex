defmodule SessionDesk.History do
  @moduledoc "Reads app-owned history without launching Pi; follows the selected JSONL branch."
  alias SessionDesk.State
  @max_bytes 32 * 1024 * 1024

  def load(record) do
    base = %State{
      status: if(record.status == "interrupted", do: :interrupted, else: :suspended),
      model: record.model,
      provider: record.provider,
      thinking: record.thinking,
      session_file: record.file
    }

    case File.stat(record.file) do
      {:error, :enoent} ->
        base

      {:ok, %{size: size}} when size <= @max_bytes ->
        with {:ok, bytes} <- File.read(record.file),
             {:ok, messages} <- messages(bytes, record.mode) do
          view = State.restore(base, Enum.take(messages, -500))

          if length(messages) > 500,
            do:
              State.notice(
                view,
                "Showing the latest 500 saved messages. Full history remains on disk."
              ),
            else: view
        else
          _ -> State.notice(base, "Saved history could not be read. The file has been preserved.")
        end

      {:ok, _} ->
        State.notice(
          base,
          "History is larger than the 32 MB preview limit. Resume it in Pi to continue."
        )

      {:error, reason} ->
        State.notice(base, "Could not read history: #{inspect(reason)}")
    end
  end

  def messages(bytes, "demo") do
    case Jason.decode(bytes) do
      {:ok, messages} when is_list(messages) ->
        if(Enum.all?(messages, &is_map/1), do: {:ok, messages}, else: {:error, :invalid_history})

      _ ->
        {:error, :invalid_history}
    end
  end

  def messages(bytes, "live") do
    # A final incomplete line can be left by abrupt termination; never rewrite it.
    entries =
      bytes
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"id" => _} = e} -> [e]
          _ -> []
        end
      end)

    index = Map.new(entries, &{&1["id"], &1})
    branch = walk(List.last(entries), index, MapSet.new(), [])

    {:ok,
     for(%{"type" => "message", "message" => message} <- branch, is_map(message), do: message)}
  end

  defp walk(nil, _, _, acc), do: acc

  defp walk(entry, index, seen, acc) do
    if MapSet.member?(seen, entry["id"]) do
      acc
    else
      walk(index[entry["parentId"]], index, MapSet.put(seen, entry["id"]), [entry | acc])
    end
  end
end
