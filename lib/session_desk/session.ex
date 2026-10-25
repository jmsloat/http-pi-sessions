defmodule SessionDesk.Session do
  use GenServer, restart: :temporary
  alias SessionDesk.{Protocol, State}

  @moduledoc "Owns the RPC subprocess independently of LiveView connections. No automatic prompt replay."

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:id] || "main"))
  def via(id), do: {:via, Registry, {SessionDesk.Registry, id}}
  def snapshot(id \\ "main"), do: GenServer.call(via(id), :snapshot)
  def command(action, id \\ "main"), do: GenServer.call(via(id), {:command, action})
  def subscribe(id \\ "main"), do: Phoenix.PubSub.subscribe(SessionDesk.PubSub, "session:" <> id)

  def start_default do
    DynamicSupervisor.start_child(SessionDesk.SessionSupervisor, {__MODULE__, id: "main"})
  end

  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      id: opts[:id] || "main",
      view: %State{},
      os_pid: nil,
      child: nil,
      buffer: "",
      pending: %{},
      seq: 0,
      flush: nil,
      opts: opts
    }

    {:ok, state, {:continue, :launch}}
  end

  def handle_continue(:launch, s) do
    case launch(s.opts) do
      {:ok, child, os_pid} ->
        s = %{s | child: child, os_pid: os_pid}
        {:noreply, request(s, "get_state")}

      {:error, reason} ->
        {:noreply,
         publish(%{
           s
           | view:
               State.notice(%{s.view | status: :error}, "Could not start Pi: #{inspect(reason)}")
         })}
    end
  end

  def handle_call(:snapshot, _, s), do: {:reply, s.view, s}

  def handle_call({:command, {:prompt, text}}, _, s) do
    text = String.trim(text)

    cond do
      s.view.status != :idle ->
        {:reply, {:error, "Wait for the current run or stop it first."}, s}

      text == "" or byte_size(text) > 100_000 ->
        {:reply, {:error, "Enter a message under 100 KB."}, s}

      true ->
        s = request(%{s | view: %{s.view | status: :working}}, "prompt", %{"message" => text})
        {:reply, :ok, publish(s)}
    end
  end

  def handle_call({:command, :abort}, _, s) do
    if s.os_pid do
      # No steering/follow-up queue is exposed in this prototype.
      {:reply, :ok, request(%{s | view: %{s.view | status: :stopping}}, "abort") |> publish()}
    else
      {:reply, {:error, "Agent is not running."}, s}
    end
  end

  def handle_call({:command, {:answer, id, answer}}, _, s) do
    q = Enum.find(s.view.questions, &(&1["id"] == id))

    with true <- not is_nil(q),
         true <- valid_answer?(q, answer),
         :ok <-
           send_record(s, Map.merge(answer, %{"type" => "extension_ui_response", "id" => id})) do
      questions = Enum.reject(s.view.questions, &(&1["id"] == id))

      view = %{
        s.view
        | questions: questions,
          status: if(questions == [], do: :working, else: :waiting)
      }

      {:reply, :ok, publish(%{s | view: view})}
    else
      _ ->
        {:reply,
         {:error, "This question expired, was answered elsewhere, or the answer is invalid."}, s}
    end
  end

  def handle_call({:command, :restart}, _, %{os_pid: nil} = s),
    do:
      {:reply, :ok, %{s | view: %State{revision: s.view.revision}, buffer: "", pending: %{}},
       {:continue, :launch}}

  def handle_call({:command, _}, _, s), do: {:reply, {:error, "Action unavailable."}, s}

  def handle_info({:stdout, pid, bytes}, %{os_pid: pid} = s) do
    case Protocol.feed(s.buffer, bytes) do
      {:ok, records, buffer} ->
        s =
          Enum.reduce(records, %{s | buffer: buffer}, fn
            {:ok, event}, acc when is_map(event) ->
              consume(acc, event)

            _, acc ->
              %{acc | view: State.notice(acc.view, "Invalid JSON record received from agent.")}
          end)

        {:noreply, schedule(s)}

      {:error, reason} ->
        :exec.stop(s.child)

        {:noreply,
         publish(%{
           s
           | view: State.notice(%{s.view | status: :error}, "RPC framing failure: #{reason}")
         })}
    end
  end

  def handle_info({:stderr, pid, bytes}, %{os_pid: pid} = s),
    do: {:noreply, schedule(%{s | view: State.notice(s.view, String.slice(bytes, 0, 2000))})}

  def handle_info({:EXIT, child, reason}, %{child: child} = s) do
    view =
      State.notice(
        %{s.view | status: :interrupted, questions: [], active_message: nil},
        "Agent exited: #{inspect(reason)}. Resume opens saved history; it does not repeat your prompt."
      )

    {:noreply, publish(%{s | child: nil, os_pid: nil, pending: %{}, view: view})}
  end

  def handle_info({:expire_question, id}, s) do
    questions = Enum.reject(s.view.questions, &(&1["id"] == id))
    status = if s.view.status == :waiting and questions == [], do: :working, else: s.view.status
    {:noreply, publish(%{s | view: %{s.view | questions: questions, status: status}})}
  end

  def handle_info(:flush, s), do: {:noreply, publish(%{s | flush: nil})}
  def handle_info(_, s), do: {:noreply, s}
  def terminate(_, s), do: if(s.child, do: :exec.stop(s.child))

  defp consume(s, %{"type" => "response", "id" => id} = event) do
    {kind, pending} = Map.pop(s.pending, id)
    s = %{s | pending: pending, view: State.apply(s.view, event)}

    case {kind, event["success"], event["data"]} do
      {"get_state", true, data} ->
        request(
          %{
            s
            | view: %{
                s.view
                | model: get_in(data, ["model", "id"]),
                  session_file: data["sessionFile"]
              }
          },
          "get_messages"
        )

      {"get_messages", true, %{"messages" => messages}} ->
        %{s | view: %{State.restore(s.view, messages) | status: :idle}}

      {"prompt", false, _} ->
        %{s | view: %{s.view | status: :idle}}

      {"abort", true, _} ->
        %{s | view: %{s.view | status: :idle, questions: [], active_message: nil}}

      {kind, false, _} when kind in ["get_state", "get_messages"] ->
        %{s | view: %{s.view | status: :error}}

      _ ->
        s
    end
  end

  defp consume(s, event) do
    if event["type"] == "extension_ui_request" and is_integer(event["timeout"]),
      do: Process.send_after(self(), {:expire_question, event["id"]}, max(0, event["timeout"]))

    %{s | view: State.apply(s.view, event)}
  end

  defp request(s, type, attrs \\ %{}) do
    id = "request-#{s.seq + 1}"

    case send_record(s, Map.merge(attrs, %{"id" => id, "type" => type})) do
      :ok -> %{s | seq: s.seq + 1, pending: Map.put(s.pending, id, type)}
      error -> %{s | view: State.notice(%{s.view | status: :error}, inspect(error))}
    end
  end

  defp send_record(%{os_pid: nil}, _), do: {:error, :not_running}
  defp send_record(s, value), do: :exec.send(s.os_pid, Jason.encode!(value) <> "\n")
  defp valid_answer?(_, %{"cancelled" => true}), do: true
  defp valid_answer?(%{"method" => "confirm"}, %{"confirmed" => b}), do: is_boolean(b)
  defp valid_answer?(%{"method" => "select", "options" => opts}, %{"value" => v}), do: v in opts

  defp valid_answer?(%{"method" => m}, %{"value" => v}) when m in ["input", "editor"],
    do: is_binary(v) and byte_size(v) <= 100_000

  defp valid_answer?(_, _), do: false
  defp schedule(%{flush: nil} = s), do: %{s | flush: Process.send_after(self(), :flush, 40)}
  defp schedule(s), do: s

  defp publish(s) do
    s = %{s | view: %{s.view | revision: s.view.revision + 1}}
    Phoenix.PubSub.broadcast(SessionDesk.PubSub, "session:" <> s.id, {:session, s.view})
    s
  end

  defp launch(opts) do
    root = Application.fetch_env!(:session_desk, :data_dir)
    File.mkdir_p!(root)
    mode = Application.fetch_env!(:session_desk, :mode)

    {executable, args} =
      if opts[:command] do
        opts[:command]
      else
        case mode do
          "demo" ->
            {System.find_executable("node"),
             [
               Path.join(:code.priv_dir(:session_desk), "demo_agent.mjs"),
               Path.join(root, "demo.json")
             ]}

          "live" ->
            {System.find_executable(Application.fetch_env!(:session_desk, :pi_executable)),
             ["--mode", "rpc", "--session", Path.join(root, "pi-session.jsonl")] ++
               Application.fetch_env!(:session_desk, :pi_args)}
        end
      end

    env = [{"GENTLE_SHELL_INTERACTIVE_HOST", "1"}]

    env =
      if home = Application.get_env(:session_desk, :pi_home),
        do: [{"PI_CODING_AGENT_DIR", home} | env],
        else: env

    env = (opts[:env] || []) ++ env

    if executable do
      :exec.run_link([executable | args], [
        :stdin,
        :stdout,
        :stderr,
        :kill_group,
        {:group, 0},
        {:kill_timeout, 2},
        {:cd, opts[:workspace] || Application.fetch_env!(:session_desk, :workspace)},
        {:env, env}
      ])
    else
      {:error, :executable_not_found}
    end
  end
end
