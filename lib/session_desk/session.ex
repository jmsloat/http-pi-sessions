defmodule SessionDesk.Session do
  use GenServer, restart: :temporary, shutdown: 10_000
  alias SessionDesk.{Protocol, State}

  @moduledoc "Owns the RPC subprocess independently of LiveView connections. No automatic prompt replay."

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:id] || "main"))
  def via(id), do: {:via, Registry, {SessionDesk.Registry, id}}
  def snapshot(id \\ "main"), do: GenServer.call(via(id), :snapshot)
  def command(action, id \\ "main"), do: GenServer.call(via(id), {:command, action}, 15_000)
  def subscribe(id \\ "main"), do: Phoenix.PubSub.subscribe(SessionDesk.PubSub, "session:" <> id)

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
      hydrated: false,
      persisted: nil,
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

  def handle_call({:command, :suspend}, _, s) do
    if s.view.status in [:idle, :interrupted, :error] do
      {:stop, :normal, {:ok, s.view}, s}
    else
      {:reply, {:error, "Wait for this session to finish or stop its current run."}, s}
    end
  end

  def handle_call({:command, {:set_model, provider, model}}, _, s) do
    if s.view.status == :idle and
         Enum.any?(s.view.models, &(&1["provider"] == provider and &1["id"] == model)) do
      s =
        request(%{s | view: %{s.view | status: :configuring}}, "set_model", %{
          "provider" => provider,
          "modelId" => model
        })

      {:reply, :ok, publish(s)}
    else
      {:reply, {:error, "Choose an available model while the session is idle."}, s}
    end
  end

  def handle_call({:command, {:set_thinking, level}}, _, s) do
    if s.view.status == :idle and s.view.reasoning and
         level in ["off", "minimal", "low", "medium", "high", "xhigh"] do
      s =
        request(%{s | view: %{s.view | status: :configuring}}, "set_thinking_level", %{
          "level" => level
        })

      {:reply, :ok, publish(s)}
    else
      {:reply, {:error, "Thinking controls require an idle session and a reasoning model."}, s}
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
      {:reply, :ok,
       %{s | view: %State{revision: s.view.revision}, buffer: "", pending: %{}, hydrated: false},
       {:continue, :launch}}

  def handle_call({:command, :restart}, _, %{view: %{status: status}} = s)
      when status in [:error, :interrupted] do
    stop_child(s)

    {:reply, :ok,
     %{
       s
       | child: nil,
         os_pid: nil,
         view: %State{revision: s.view.revision},
         buffer: "",
         pending: %{},
         hydrated: false
     }, {:continue, :launch}}
  end

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

  def handle_info({:request_timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {request, pending} ->
        if s.child, do: :exec.stop(s.child)

        view =
          State.notice(
            %{s.view | status: :error},
            "Pi did not answer #{request.type}. Resume when ready; no prompt will be replayed."
          )

        {:noreply, publish(%{s | pending: pending, view: view})}
    end
  end

  def handle_info(:flush, s), do: {:noreply, publish(%{s | flush: nil})}
  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s), do: stop_child(s)

  defp stop_child(s) do
    if s.child && Process.alive?(s.child) do
      ref = Process.monitor(s.child)
      :exec.stop(s.child)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        5_000 ->
          :exec.kill(s.os_pid, 9)

          receive do
            {:DOWN, ^ref, :process, _, _} -> :ok
          after
            2_000 -> :ok
          end
      end
    end
  end

  defp consume(s, %{"type" => "response", "id" => id} = event) do
    {request, pending} = Map.pop(s.pending, id)
    kind = if request, do: request.type
    if request, do: Process.cancel_timer(request.timer)
    s = %{s | pending: pending, view: State.apply(s.view, event)}

    case {kind, event["success"], event["data"]} do
      {"get_state", true, data} ->
        view = %{
          s.view
          | model: get_in(data, ["model", "id"]),
            provider: get_in(data, ["model", "provider"]),
            reasoning: get_in(data, ["model", "reasoning"]) == true,
            thinking: data["thinkingLevel"],
            session_file: data["sessionFile"]
        }

        if s.hydrated do
          %{s | view: %{view | status: :idle}}
        else
          request(%{s | view: view}, "get_messages")
        end

      {"get_messages", true, %{"messages" => messages}} ->
        request(
          %{s | hydrated: true, view: State.restore(s.view, messages)},
          "get_available_models"
        )

      {"get_available_models", true, %{"models" => models}} ->
        models = Enum.map(models, &Map.take(&1, ["id", "provider", "name", "reasoning"]))
        %{s | view: %{s.view | models: models, status: :idle}}

      {kind, true, _} when kind in ["set_model", "set_thinking_level"] ->
        request(s, "get_state")

      {kind, false, _} when kind in ["set_model", "set_thinking_level", "get_available_models"] ->
        %{s | view: %{s.view | status: :idle}}

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
    s = %{s | view: %{s.view | command_error: nil}}
    id = "request-#{s.seq + 1}"

    case send_record(s, Map.merge(attrs, %{"id" => id, "type" => type})) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, id}, 30_000)
        %{s | seq: s.seq + 1, pending: Map.put(s.pending, id, %{type: type, timer: timer})}

      error ->
        %{s | view: State.notice(%{s.view | status: :error}, inspect(error))}
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

    Phoenix.PubSub.broadcast(
      SessionDesk.PubSub,
      "session:" <> s.id,
      {:session, s.id, self(), s.view}
    )

    fingerprint = {s.view.status, s.view.provider, s.view.model, s.view.thinking}

    if s.opts[:catalog] && fingerprint != s.persisted do
      SessionDesk.Catalog.changed(s.opts[:catalog], s.id, self(), s.view)
    end

    preferences =
      Map.merge(
        s.opts[:preferences] || %{},
        Enum.reject(
          %{provider: s.view.provider, model: s.view.model, thinking: s.view.thinking},
          fn {_, value} -> is_nil(value) end
        )
        |> Map.new()
      )

    %{s | persisted: fingerprint, opts: Keyword.put(s.opts, :preferences, preferences)}
  end

  defp launch(opts) do
    root = Application.fetch_env!(:session_desk, :data_dir)
    File.mkdir_p!(root)
    mode = opts[:mode] || Application.fetch_env!(:session_desk, :mode)

    file =
      opts[:session_file] ||
        Path.join(root, if(mode == "demo", do: "demo.json", else: "pi-session.jsonl"))

    File.mkdir_p!(Path.dirname(file))
    preferences = opts[:preferences] || %{}

    model_args =
      if preferences[:provider] && preferences[:model],
        do: ["--provider", preferences.provider, "--model", preferences.model],
        else: []

    thinking_args = if preferences[:thinking], do: ["--thinking", preferences.thinking], else: []

    {executable, args} =
      if opts[:command] do
        opts[:command]
      else
        case mode do
          "demo" ->
            {System.find_executable("node"),
             [
               Path.join(:code.priv_dir(:session_desk), "demo_agent.mjs"),
               file,
               preferences[:model] || "scripted-demo",
               preferences[:thinking] || "off"
             ]}

          "live" ->
            {System.find_executable(Application.fetch_env!(:session_desk, :pi_executable)),
             ["--mode", "rpc", "--session", file] ++
               Application.fetch_env!(:session_desk, :pi_args) ++ model_args ++ thinking_args}
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
