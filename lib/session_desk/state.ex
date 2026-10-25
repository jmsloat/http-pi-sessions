defmodule SessionDesk.State do
  @moduledoc "Read-only projection of Pi events; Gentle owns to-do mutations."
  defstruct status: :starting,
            messages: [],
            active_message: nil,
            tasks: [],
            todo_seen: false,
            questions: [],
            tools: [],
            notices: [],
            command_error: nil,
            revision: 0,
            model: nil,
            provider: nil,
            reasoning: false,
            thinking: nil,
            models: [],
            session_file: nil,
            turn: 0,
            updated_turn: nil

  def apply(state, event), do: %{reduce(state, event) | revision: state.revision + 1}

  defp reduce(s, %{"type" => "thinking_level_changed", "level" => level}),
    do: %{s | thinking: level}

  defp reduce(s, %{"type" => "agent_start"}), do: %{s | status: :working}

  defp reduce(s, %{"type" => "agent_end"}),
    do: %{s | status: :settling, active_message: nil, questions: []}

  defp reduce(s, %{"type" => "agent_settled"}),
    do: %{s | status: :idle, active_message: nil, questions: []}

  defp reduce(s, %{"type" => "message_start", "message" => m}) do
    case m["role"] do
      "user" ->
        %{s | messages: s.messages ++ [display(m)], turn: s.turn + 1}

      "assistant" ->
        %{s | messages: s.messages ++ [display(m)], active_message: length(s.messages)}

      _ ->
        s
    end
  end

  defp reduce(s, %{"type" => "message_update", "message" => m}), do: update_message(s, m)

  defp reduce(%{active_message: index} = s, %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}
       })
       when is_integer(index) do
    %{s | messages: List.update_at(s.messages, index, &%{&1 | text: &1.text <> delta})}
  end

  defp reduce(s, %{"type" => "message_end", "message" => m}) do
    s = if m["role"] == "assistant", do: %{update_message(s, m) | active_message: nil}, else: s
    if m["role"] == "toolResult", do: todo(s, m["details"]), else: s
  end

  defp reduce(s, %{"type" => "tool_execution_start"} = e) do
    tool = %{
      id: e["toolCallId"],
      name: e["toolName"],
      args: e["args"],
      output: nil,
      status: :working
    }

    %{s | tools: Enum.take([tool | s.tools], 100)}
  end

  defp reduce(s, %{"type" => "tool_execution_end"} = e) do
    result = e["result"] || %{}

    tools =
      Enum.map(s.tools, fn t ->
        if t.id == e["toolCallId"],
          do: %{t | output: result, status: if(e["isError"], do: :error, else: :done)},
          else: t
      end)

    todo(%{s | tools: tools}, result["details"])
  end

  defp reduce(s, %{"type" => "extension_ui_request", "method" => method} = e)
       when method in ["select", "confirm", "input", "editor"] do
    %{s | status: :waiting, questions: s.questions ++ [e]}
  end

  defp reduce(
         s,
         %{
           "type" => "extension_ui_request",
           "method" => "setWidget",
           "widgetKey" => "gentle-todo"
         } = e
       ) do
    if is_nil(e["widgetLines"]), do: %{s | tasks: []}, else: s
  end

  defp reduce(s, %{"type" => "extension_ui_request", "method" => "notify", "message" => text}),
    do: notice(s, text)

  defp reduce(s, %{"type" => "response", "success" => false} = e),
    do:
      notice(
        %{s | command_error: e["error"] || "Command rejected"},
        e["error"] || "Command rejected"
      )

  defp reduce(s, _), do: s

  def restore(s, messages) do
    base = %{s | messages: [], tasks: [], tools: [], turn: 0, updated_turn: nil}

    restored =
      Enum.reduce(messages, base, fn m, acc ->
        acc =
          case m["role"] do
            role when role in ["user", "assistant"] ->
              %{
                acc
                | messages: acc.messages ++ [display(m)],
                  turn: acc.turn + if(role == "user", do: 1, else: 0)
              }

            _ ->
              acc
          end

        if m["role"] == "toolResult" do
          tool = %{
            id: m["toolCallId"] || "saved-#{length(acc.tools)}",
            name: m["toolName"],
            args: nil,
            output: Map.take(m, ["content", "details"]),
            status: if(m["isError"], do: :error, else: :done)
          }

          todo(%{acc | tools: Enum.take([tool | acc.tools], 100)}, m["details"])
        else
          acc
        end
      end)

    # Gentle hides a completed list when reopening a saved session.
    if Enum.all?(restored.tasks, &(&1["status"] in ["done", "dropped"])),
      do: %{restored | tasks: []},
      else: restored
  end

  def todo(s, %{"gentleTodo" => %{"tasks" => tasks} = snapshot}) when is_list(tasks),
    do: %{s | tasks: tasks, todo_seen: true, updated_turn: snapshot["updatedTurn"]}

  def todo(s, _), do: s
  def notice(s, text), do: %{s | notices: Enum.take([to_string(text) | s.notices], 8)}
  def text(content) when is_binary(content), do: content

  def text(content) when is_list(content),
    do: Enum.map_join(content, "\n", &if(&1["type"] == "text", do: &1["text"] || "", else: ""))

  def text(_), do: ""
  defp display(m), do: %{role: m["role"], text: text(m["content"]), error: m["errorMessage"]}
  defp update_message(%{active_message: nil} = s, _), do: s

  defp update_message(s, m),
    do: %{s | messages: List.replace_at(s.messages, s.active_message, display(m))}
end
