defmodule SessionDeskWeb.DeskLive do
  use Phoenix.LiveView
  alias SessionDesk.Session

  def mount(_, _, socket) do
    if connected?(socket), do: Session.subscribe()

    view =
      case Registry.lookup(SessionDesk.Registry, "main") do
        [] -> %SessionDesk.State{status: :interrupted}
        _ -> Session.snapshot()
      end

    {:ok,
     assign(socket,
       view: view,
       draft: "",
       error: nil,
       mode: Application.fetch_env!(:session_desk, :mode),
       workspace: Application.fetch_env!(:session_desk, :workspace)
     )}
  end

  def handle_info({:session, view}, socket) do
    if view.revision >= socket.assigns.view.revision,
      do: {:noreply, assign(socket, :view, view)},
      else: {:noreply, socket}
  end

  def handle_event("draft", %{"message" => text}, socket),
    do: {:noreply, assign(socket, :draft, text)}

  def handle_event("send", %{"message" => text}, socket) do
    case Session.command({:prompt, text}) do
      :ok -> {:noreply, assign(socket, draft: "", error: nil) |> push_event("clear_draft", %{})}
      {:error, error} -> {:noreply, assign(socket, :error, error)}
    end
  end

  def handle_event("stop", _, socket), do: result(socket, Session.command(:abort))
  def handle_event("resume", _, socket), do: result(socket, Session.command(:restart))

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

    result(socket, Session.command({:answer, params["id"] || params["question_id"], answer}))
  end

  defp result(socket, :ok), do: {:noreply, assign(socket, :error, nil)}
  defp result(socket, {:error, error}), do: {:noreply, assign(socket, :error, error)}
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

  defp stale(view) do
    if is_integer(view.updated_turn) and
         Enum.any?(view.tasks, &(&1["status"] in ["pending", "in_progress"])),
       do: max(0, view.turn - view.updated_turn),
       else: 0
  end

  def render(assigns) do
    ~H"""
    <div class="desk">
      <nav class="rail" aria-label="Workspace navigation">
        <a class="brand" href="/"><span class="brand-mark">s/</span> Session Desk</a>
        <div class="rail-label">WORKSPACE</div>
        <div class="project">
          <span>◇</span>
          <div><strong>{Path.basename(@workspace)}</strong><small>Local project</small></div>
        </div>
        <div class="rail-label sessions-label">SESSIONS <span>01</span></div>
        <a class="session-link active" href="/">
          <span class={"dot #{@view.status}"}></span>
          <div><strong>Integration prototype</strong><small>{label(@view.status)}</small></div>
        </a>
        <div class="rail-bottom">
          <span class="local-dot"></span>
          Single-user workspace<br /><small>Pi + Gentle Shell · Phoenix LiveView</small>
        </div>
      </nav>
      <main>
        <header class="topbar">
          <div>
            <div class="breadcrumb">{Path.basename(@workspace)} <span>/</span> Session</div>
            <h1>Integration prototype</h1>
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
        <div class="work-area">
          <section class="conversation" aria-label="Conversation">
            <div id="transcript" phx-hook="Transcript" class="transcript" aria-live="polite">
              <div :if={@view.messages == []} class="empty-chat">
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
                :if={message.role == "user" or message.text != "" or @view.active_message == index}
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
                <div class="message-text">{if message.text == "", do: "…", else: message.text}</div>
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
              <div :if={@error} class="error" role="alert">{@error}</div>
              <div :if={@view.status in [:interrupted, :error]} class="recovery">
                <span>Session needs attention.</span><button phx-click="resume">Resume saved session</button>
              </div>
              <form id="composer" phx-submit="send" phx-change="draft" class="composer">
                <textarea
                  id="draft"
                  name="message"
                  phx-hook="Draft"
                  value={@draft}
                  aria-label="Message your agent"
                  placeholder="Message your agent…"
                  rows="3"
                >{@draft}</textarea>
                <div class="composer-footer">
                  <span>⌘ / Ctrl + Enter to send</span><button
                    :if={@view.status in [:working, :waiting, :stopping]}
                    type="button"
                    phx-click="stop"
                    disabled={@view.status == :stopping}
                  >■ Stop</button><button
                    type="submit"
                    class="primary"
                    disabled={@view.status != :idle}
                  >Send <span>↑</span></button>
                </div>
              </form>
              <div class="composer-note">Closing this page won’t stop the session.</div>
            </div>
          </section>
          <aside class="inspector" aria-label="Session details">
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
              <div :if={stale(@view) >= 2} class="stale">Plan unchanged for {stale(@view)} turns</div>
              <div class="panel-footnote">Read-only · managed by Gentle</div>
            </section>
            <section class="activity-panel">
              <div class="panel-heading">
                <h2>Tool activity</h2>
                <span>{length(@view.tools)}</span>
              </div>
              <p :if={@view.tools == []} class="muted">Tool calls will appear as the agent works.</p>
              <details :for={tool <- @view.tools} id={"tool-#{tool.id}"} class="tool">
                <summary>
                  <span>{if tool.status == :working, do: "◐", else: "✓"}</span>{tool.name}<small>{tool.status}</small>
                </summary>
                <pre>{pretty(tool.args)}</pre><pre :if={tool.output}>{pretty(tool.output)}</pre>
              </details>
            </section>
            <details :if={@view.notices != []} class="diagnostics">
              <summary>Diagnostics · {length(@view.notices)}</summary>
              <pre :for={notice <- @view.notices}>{notice}</pre>
            </details>
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
