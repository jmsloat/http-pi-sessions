defmodule SessionDeskWeb.DeskLive do
  use Phoenix.LiveView
  alias SessionDesk.{Session, Catalog, History, State}

  def mount(_, _, socket) do
    if connected?(socket), do: Catalog.subscribe()

    {:ok,
     assign(socket,
       view: %State{},
       selected: nil,
       session_id: nil,
       controller: nil,
       draft: "",
       error: nil,
       mode: Application.fetch_env!(:session_desk, :mode),
       workspace: "",
       workspace_id: nil,
       catalog: Catalog.list(),
       show_archived: false,
       navigation_open: false,
       inspector_tab: "activity"
     )}
  end

  def handle_params(params, _, socket) do
    catalog = Catalog.list()

    id =
      params["id"] ||
        case Enum.find(catalog.sessions, &(not &1.archived)) || List.first(catalog.sessions) do
          nil -> nil
          record -> record.id
        end

    case Catalog.get(id) do
      nil ->
        {:noreply, push_navigate(socket, to: "/")}

      record ->
        if connected?(socket) do
          if socket.assigns.session_id,
            do:
              Phoenix.PubSub.unsubscribe(
                SessionDesk.PubSub,
                "session:" <> socket.assigns.session_id
              )

          Session.subscribe(id)
        end

        {:noreply,
         assign(socket,
           catalog: catalog,
           selected: record,
           session_id: id,
           workspace: record.path,
           workspace_id: record.workspace_id,
           view: snapshot(record),
           controller: GenServer.whereis(Session.via(id)),
           draft: "",
           error: nil,
           navigation_open: false
         )
         |> canonical_url(params, id)}
    end
  end

  defp canonical_url(socket, params, id) do
    if connected?(socket) and is_nil(params["id"]),
      do: push_patch(socket, to: "/sessions/" <> id, replace: true),
      else: socket
  end

  def handle_info({:session, id, pid, view}, %{assigns: %{session_id: id}} = socket) do
    current = GenServer.whereis(Session.via(id))

    if pid == current and
         (pid != socket.assigns.controller or view.revision >= socket.assigns.view.revision),
       do: {:noreply, assign(socket, view: view, controller: pid)},
       else: {:noreply, socket}
  end

  def handle_info({:session, _, _, _}, socket), do: {:noreply, socket}

  def handle_info({:session_closed, id}, %{assigns: %{session_id: id}} = socket),
    do: refresh(socket)

  def handle_info({:session_closed, _}, socket), do: {:noreply, socket}
  def handle_info(:catalog_changed, socket), do: refresh(socket)

  def handle_event(_, %{"session_id" => id}, %{assigns: %{session_id: current}} = socket)
      when id != current,
      do: {:noreply, socket}

  def handle_event(event, %{"session_id" => id, "message" => text}, socket)
      when event in ["draft", "restore_draft"] do
    if id == socket.assigns.session_id,
      do: {:noreply, assign(socket, :draft, text)},
      else: {:noreply, socket}
  end

  def handle_event("inspector", %{"tab" => tab}, socket) when tab in ["activity", "files"],
    do: {:noreply, assign(socket, :inspector_tab, tab)}

  def handle_event("navigation", _, socket),
    do: {:noreply, assign(socket, :navigation_open, not socket.assigns.navigation_open)}

  def handle_event("show_archived", _, socket),
    do: {:noreply, assign(socket, :show_archived, not socket.assigns.show_archived)}

  def handle_event("workspace", %{"workspace_id" => id}, socket),
    do: {:noreply, assign(socket, :workspace_id, id)}

  def handle_event("add_workspace", %{"name" => name, "path" => path}, socket) do
    case Catalog.add_workspace(name, path) do
      {:ok, id} ->
        {:noreply, assign(socket, catalog: Catalog.list(), workspace_id: id, error: nil)}

      error ->
        result(socket, error)
    end
  end

  def handle_event("new_session", %{"title" => title, "workspace_id" => workspace}, socket) do
    case Catalog.create_session(workspace, title) do
      {:ok, id} -> {:noreply, push_patch(socket, to: "/sessions/" <> id)}
      error -> result(socket, error)
    end
  end

  def handle_event("rename", %{"title" => title}, socket),
    do: result(socket, Catalog.rename(socket.assigns.session_id, title))

  def handle_event("archive", _, socket),
    do:
      result(
        socket,
        Catalog.archive(socket.assigns.session_id, not socket.assigns.selected.archived)
      )

  def handle_event("suspend", _, socket),
    do: result(socket, Catalog.suspend(socket.assigns.session_id))

  def handle_event("send", %{"message" => text}, socket) do
    case command(socket, {:prompt, text}) do
      :ok ->
        {:noreply,
         assign(socket, draft: "", error: nil)
         |> push_event("clear_draft", %{session_id: socket.assigns.session_id})}

      error ->
        result(socket, error)
    end
  end

  def handle_event("model", %{"model" => value}, socket) do
    case Jason.decode(value) do
      {:ok, [provider, model]} -> result(socket, command(socket, {:set_model, provider, model}))
      _ -> result(socket, {:error, "Choose an available model."})
    end
  end

  def handle_event("thinking", %{"thinking" => level}, socket),
    do: result(socket, command(socket, {:set_thinking, level}))

  def handle_event("stop", _, socket), do: result(socket, command(socket, :abort))

  def handle_event("resume", _, socket) do
    case Catalog.activate(socket.assigns.session_id) do
      {:ok, _} ->
        if Session.snapshot(socket.assigns.session_id).status in [:error, :interrupted],
          do: command(socket, :restart)

        {:noreply,
         assign(socket,
           view: snapshot(socket.assigns.selected),
           controller: GenServer.whereis(Session.via(socket.assigns.session_id)),
           error: nil
         )}

      error ->
        result(socket, error)
    end
  end

  def handle_event("answer", params, socket) do
    answer =
      cond do
        params["cancel"] == "true" ->
          %{"cancelled" => true}

        params["confirmed"] in ["true", "false"] ->
          %{"confirmed" => params["confirmed"] == "true"}

        true ->
          %{"value" => params["choice"] || params["value"] || ""}
      end

    result(socket, command(socket, {:answer, params["id"] || params["question_id"], answer}))
  end

  defp command(socket, action) do
    if socket.assigns.selected.archived do
      {:error, "Restore this archived session first."}
    else
      try do
        Session.command(action, socket.assigns.session_id)
      catch
        :exit, _ -> {:error, "Session is stopped. Resume it to continue."}
      end
    end
  end

  defp snapshot(record) do
    try do
      Session.snapshot(record.id)
    catch
      :exit, _ -> History.load(record)
    end
  end

  defp refresh(socket) do
    record = Catalog.get(socket.assigns.session_id)
    socket = assign(socket, catalog: Catalog.list(), selected: record)
    # Subscriptions carry live updates; offline views read history without starting Pi.
    socket =
      if record &&
           (is_nil(socket.assigns.controller) or
              GenServer.whereis(Session.via(record.id)) != socket.assigns.controller),
         do:
           assign(socket,
             view: snapshot(record),
             controller: GenServer.whereis(Session.via(record.id))
           ),
         else: socket

    {:noreply, socket}
  end

  defp result(socket, :ok), do: {:noreply, assign(socket, :error, nil)}
  defp result(socket, {:error, error}), do: {:noreply, assign(socket, :error, error)}
  defp label(:suspended), do: "Saved · agent stopped"
  defp label(:configuring), do: "Updating model"
  defp label(:idle), do: "Ready"
  defp label(:waiting), do: "Needs your input"
  defp label(:working), do: "Working"
  defp label(status), do: status |> Atom.to_string() |> String.capitalize()
  defp glyph("done"), do: "✓"
  defp glyph("in_progress"), do: "◐"
  defp glyph("blocked"), do: "!"
  defp glyph("dropped"), do: "−"
  defp glyph(_), do: "○"
  defp pretty(term), do: Jason.encode!(term, pretty: true)

  defp present?(text) when is_binary(text), do: String.trim(text) != ""
  defp present?(_), do: false

  defp visible_message?(message),
    do: message.role == "user" or present?(message.text) or present?(message.error)

  defp stale(view) do
    if is_integer(view.updated_turn) and
         Enum.any?(view.tasks, &(&1["status"] in ["pending", "in_progress"])),
       do: max(0, view.turn - view.updated_turn),
       else: 0
  end

  def render(assigns) do
    ~H"""
    <div class="desk">
      <nav class={["rail", @navigation_open && "open"]} aria-label="Workspace navigation">
        <a class="brand" href="/"><span class="brand-mark">s/</span> Session Desk</a>
        <label class="rail-label" for="workspace-select">WORKSPACE</label>
        <form phx-change="workspace">
          <select id="workspace-select" name="workspace_id" aria-label="Workspace">
            <option
              :for={workspace <- @catalog.workspaces}
              value={workspace.id}
              selected={workspace.id == @workspace_id}
            >
              {workspace.name}
            </option>
          </select>
        </form>
        <details class="rail-form">
          <summary>Add workspace</summary>
          <form id="add-workspace" phx-submit="add_workspace">
            <label>Name<input name="name" placeholder="My project" required maxlength="100" /></label>
            <label>
              Server directory<input name="path" placeholder="/projects/my-project" required />
            </label>
            <button type="submit">Add directory</button>
          </form>
        </details>
        <div class="rail-label sessions-label">SESSIONS</div>
        <form id="new-session" class="rail-form" phx-submit="new_session">
          <input type="hidden" name="workspace_id" value={@workspace_id} />
          <input
            name="title"
            aria-label="New session name"
            placeholder="New session name"
            required
            maxlength="100"
          />
          <button type="submit">+ New session</button>
        </form>
        <div class="session-list">
          <.link
            :for={session <- @catalog.sessions}
            :if={session.workspace_id == @workspace_id and (not session.archived or @show_archived)}
            patch={"/sessions/" <> session.id}
            class={["session-link", session.id == @session_id && "active"]}
          >
            <span class={"dot #{session.status}"}></span>
            <div>
              <strong>{session.title}</strong><small>{if session.archived, do: "Archived", else: String.replace(session.status, "_", " ")}</small>
            </div>
          </.link>
        </div>
        <button class="rail-toggle" phx-click="show_archived">
          {if @show_archived, do: "Hide archived", else: "Show archived"}
        </button>
        <div class="rail-bottom">
          <span class="local-dot"></span>Single-user workspace<br />
          <small>
            Pi + Gentle Shell · Phoenix LiveView
          </small>
        </div>
      </nav>
      <main>
        <header class="topbar">
          <button
            class="navigation-toggle"
            phx-click="navigation"
            aria-label="Toggle workspaces"
            aria-expanded={to_string(@navigation_open)}
          >
            ☰
          </button>
          <div>
            <div class="breadcrumb">{Path.basename(@workspace)} <span>/</span> Session</div>
            <h1>{@selected.title}</h1>
          </div>
          <span id="session-status" class={"status #{@view.status}"}>
            <span class="dot"></span>{label(@view.status)}
          </span>
        </header>
        <div id="connection-banner" class="connection-banner">
          Connection lost. Reconnecting… Your agent continues on the server.
        </div>
        <div :if={@mode == "demo"} class="mode-banner">
          <strong>Demo mode</strong><span>Scripted RPC agent · no model calls or workspace changes</span>
        </div>
        <div :if={@mode == "live"} class="mode-banner live">
          <strong>Live Pi session</strong><span>{@view.model || "Connecting to configured model…"}</span>
        </div>
        <div class="session-controls">
          <details id={"session-actions-#{@session_id}"} phx-hook="Details" class="session-actions">
            <summary>Session settings</summary>
            <form id="rename-session" phx-submit="rename">
              <input
                name="title"
                aria-label="Session name"
                value={@selected.title}
                required
                maxlength="100"
              />
              <button type="submit">Rename</button>
            </form>
            <button
              phx-click="archive"
              disabled={@view.status not in [:idle, :suspended, :interrupted, :error]}
            >
              {if @selected.archived, do: "Restore session", else: "Archive session"}
            </button>
            <button :if={@view.status == :idle} phx-click="suspend">Suspend agent</button>
          </details>
          <form :if={@view.models != []} id="model-settings" phx-submit="model">
            <input type="hidden" name="session_id" value={@session_id} />
            <label for="model-select">Model</label>
            <select
              id="model-select"
              name="model"
              disabled={@view.status != :idle or @selected.archived}
            >
              <optgroup
                :for={
                  {provider, models} <-
                    Enum.sort_by(Enum.group_by(@view.models, & &1["provider"]), &elem(&1, 0))
                }
                label={provider}
              >
                <option
                  :for={model <- models}
                  value={Jason.encode!([provider, model["id"]])}
                  selected={provider == @view.provider and model["id"] == @view.model}
                >
                  {model["name"] || model["id"]}
                </option>
              </optgroup>
            </select>
            <button type="submit" disabled={@view.status != :idle or @selected.archived}>
              Apply model
            </button>
          </form>
          <form :if={@view.reasoning} id="thinking-settings" phx-change="thinking">
            <input type="hidden" name="session_id" value={@session_id} />
            <label for="thinking-select">Thinking</label>
            <select
              id="thinking-select"
              name="thinking"
              disabled={@view.status != :idle or @selected.archived}
              title="Pi applies the closest supported level for this model."
            >
              <option
                :for={level <- ["off", "minimal", "low", "medium", "high", "xhigh"]}
                value={level}
                selected={level == @view.thinking}
              >
                {String.capitalize(level)}
              </option>
            </select>
          </form>
        </div>
        <div class={["work-area", @inspector_tab == "files" && "reviewing"]}>
          <section class="conversation" aria-label="Conversation">
            <div
              id={"transcript-#{@session_id}"}
              phx-hook="Transcript"
              class="transcript"
              aria-live="polite"
            >
              <div :if={not Enum.any?(@view.messages, &visible_message?/1)} class="empty-chat">
                <div class="empty-symbol">↗</div>
                <div class="eyebrow">A PLACE TO PICK UP THE THREAD</div>
                <h2>What are we working on?</h2>
                <p>Chat with your agent, follow its plan, and return whenever you’re ready.</p>
                <div class="suggestion">
                  <strong>Try the integration</strong><span>Ask for a three-step plan and a question. Refresh while the agent is working.</span>
                </div>
              </div>
              <article
                :for={{message, index} <- Enum.with_index(@view.messages)}
                :if={visible_message?(message)}
                id={"message-#{index}"}
                class={"message #{message.role}"}
              >
                <div class="message-label">
                  <span class="avatar">{if message.role == "user", do: "Y", else: "π"}</span>{if message.role ==
                                                                                                   "user",
                                                                                                 do:
                                                                                                   "You",
                                                                                                 else:
                                                                                                   "Agent"}
                </div>
                <div :if={message.role == "user"} class="message-text">{message.text}</div>
                <div
                  :if={message.role == "assistant" and present?(message.text)}
                  class="message-text markdown"
                >
                  {SessionDeskWeb.Markdown.render(message.text)}
                </div>
                <div :if={present?(message.error)} class="error" role="alert">{message.error}</div>
              </article>
              <section :for={q <- @view.questions} id={"question-#{q["id"]}"} class="question">
                <div class="eyebrow">YOUR INPUT</div>
                <h3>{q["title"]}</h3>
                <p :if={q["message"]}>{q["message"]}</p>
                <div :if={q["method"] == "select"} class="choices">
                  <button
                    :for={option <- q["options"]}
                    phx-click="answer"
                    phx-value-id={q["id"]}
                    phx-value-choice={option}
                  >
                    {option}<span>↗</span>
                  </button>
                </div>
                <div :if={q["method"] == "confirm"} class="choices">
                  <button phx-click="answer" phx-value-id={q["id"]} phx-value-confirmed="true">
                    Yes
                  </button>
                  <button phx-click="answer" phx-value-id={q["id"]} phx-value-confirmed="false">
                    No
                  </button>
                </div>
                <form :if={q["method"] in ["input", "editor"]} phx-submit="answer">
                  <input type="hidden" name="question_id" value={q["id"]} />
                  <textarea
                    name="value"
                    aria-label={q["title"]}
                    placeholder={q["placeholder"] || "Your response"}
                  >{q["prefill"] || ""}</textarea>
                  <button type="submit" class="primary">Submit response</button>
                </form>
                <button
                  class="text-button"
                  phx-click="answer"
                  phx-value-id={q["id"]}
                  phx-value-cancel="true"
                >
                  Cancel question
                </button>
              </section>
            </div>
            <div class="composer-wrap">
              <div :if={@error || @view.command_error} class="error" role="alert">
                {@error || @view.command_error}
              </div>
              <div :if={@view.status in [:suspended, :interrupted, :error]} class="recovery">
                <span>
                  {if @selected.archived,
                    do: "Archived · history is preserved",
                    else: "Agent is stopped. Your history is saved."}
                </span>
                <button :if={not @selected.archived} id="resume-session" phx-click="resume">
                  Resume session
                </button>
              </div>
              <form id="composer" phx-submit="send" phx-change="draft" class="composer">
                <input type="hidden" name="session_id" value={@session_id} />
                <textarea
                  id={"draft-#{@session_id}"}
                  data-session-id={@session_id}
                  name="message"
                  phx-hook="Draft"
                  value={@draft}
                  aria-label="Message your agent"
                  placeholder="Message your agent…"
                  rows="3"
                >{@draft}</textarea>
                <div class="composer-footer">
                  <span>⌘ / Ctrl + Enter to send</span><button
                    :if={@view.status in [:working, :waiting, :stopping, :settling]}
                    type="button"
                    phx-click="stop"
                    disabled={@view.status == :stopping}
                  >■ Stop</button><button
                    type="submit"
                    class="primary"
                    disabled={@view.status != :idle or @selected.archived}
                  >Send <span>↑</span></button>
                </div>
              </form>
              <div class="composer-note">Closing this page won’t stop the session.</div>
            </div>
          </section>
          <aside class="inspector" aria-label="Session details">
            <div class="inspector-tabs" aria-label="Inspector views">
              <button
                id="activity-tab"
                phx-click="inspector"
                phx-value-tab="activity"
                aria-pressed={to_string(@inspector_tab == "activity")}
              >
                Plan &amp; tools
              </button>
              <button
                id="files-tab"
                phx-click="inspector"
                phx-value-tab="files"
                aria-pressed={to_string(@inspector_tab == "files")}
              >
                Files &amp; changes
              </button>
            </div>
            <.live_component
              :if={@inspector_tab == "files"}
              module={SessionDeskWeb.FilePanel}
              id={"workspace-files-#{@session_id}"}
              workspace={@workspace}
              agent_status={@view.status}
            />
            <div :if={@inspector_tab == "activity"}>
              <section class="task-panel">
                <div class="panel-heading">
                  <h2>Gentle Todo</h2>
                  <span>
                    {Enum.count(@view.tasks, &(&1["status"] == "done"))}/{Enum.count(
                      @view.tasks,
                      &(&1["status"] != "dropped")
                    )}
                  </span>
                </div>
                <div :if={@view.tasks == []} class="empty-tasks">
                  <span>☷</span>
                  <p>No active plan yet</p>
                  <small>The agent’s Gentle Todo list will appear here when it creates one.</small>
                </div>
                <div :for={task <- @view.tasks} class={"task #{task["status"]}"}>
                  <span class="task-glyph">{glyph(task["status"])}</span>
                  <div>
                    <strong>{task["title"]}</strong><small :if={task["note"]}>{task["note"]}</small><small class="task-status">{String.replace(task["status"], "_", " ")}</small>
                  </div>
                </div>
                <div :if={stale(@view) >= 2} class="stale">
                  Plan unchanged for {stale(@view)} turns
                </div>
                <div class="panel-footnote">Read-only · managed by Gentle</div>
              </section>
              <section class="activity-panel">
                <div class="panel-heading">
                  <h2>Tool activity</h2>
                  <span>{length(@view.tools)}</span>
                </div>
                <p :if={@view.tools == []} class="muted">
                  Tool calls will appear as the agent works.
                </p>
                <details
                  :for={tool <- @view.tools}
                  id={"tool-#{tool.id}"}
                  phx-hook="Details"
                  class="tool"
                >
                  <summary>
                    <span>
                      {case tool.status do
                        :working -> "◐"
                        :error -> "!"
                        _ -> "✓"
                      end}
                    </span>
                    {tool.name}<small>{tool.status}</small>
                  </summary>
                  <pre :if={tool.args}>{pretty(tool.args)}</pre>
                  <pre :if={tool.output}>{State.text(tool.output["content"])}</pre>
                  <details :if={tool.output && tool.output["details"]}>
                    <summary>Structured result</summary>
                    <pre>{pretty(tool.output["details"])}</pre>
                  </details>
                </details>
              </section>
              <details :if={@view.notices != []} class="diagnostics">
                <summary>Diagnostics · {length(@view.notices)}</summary>
                <pre :for={notice <- @view.notices}>{notice}</pre>
              </details>
            </div>
            <div class="workspace-info">
              <span class="rail-label">WORKING DIRECTORY</span><code>{@workspace}</code>
            </div>
          </aside>
        </div>
      </main>
    </div>
    """
  end
end
