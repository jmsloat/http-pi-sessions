defmodule SessionDeskWeb.FilePanel do
  use Phoenix.LiveComponent
  alias SessionDesk.Workspace

  def update(assigns, socket) do
    initial = not Map.has_key?(socket.assigns, :directory)

    finished =
      not initial and socket.assigns.agent_status != :idle and assigns.agent_status == :idle

    socket = assign(socket, assigns)

    socket =
      if initial do
        socket
        |> assign(
          directory: "",
          inventory: nil,
          loading: false,
          preview_loading: false,
          selection: nil,
          preview: nil,
          preview_error: nil
        )
        |> load_inventory()
      else
        if finished, do: reload(socket), else: socket
      end

    {:ok, socket}
  end

  def handle_event("browse", %{"path" => path}, socket) do
    {:noreply, socket |> assign(directory: path) |> load_inventory()}
  end

  def handle_event("preview", %{"path" => path}, socket),
    do: {:noreply, load_preview(socket, {:file, path})}

  def handle_event("diff", %{"path" => path, "area" => area}, socket),
    do: {:noreply, load_preview(socket, {:diff, path, area})}

  def handle_event("refresh", _, socket), do: {:noreply, reload(socket)}

  def handle_event("close_preview", _, socket) do
    {:noreply,
     socket
     |> cancel_async(:preview)
     |> assign(selection: nil, preview: nil, preview_error: nil, preview_loading: false)}
  end

  defp reload(socket) do
    socket = load_inventory(socket)
    if socket.assigns.selection, do: load_preview(socket, socket.assigns.selection), else: socket
  end

  defp load_inventory(socket) do
    root = socket.assigns.workspace
    directory = socket.assigns.directory

    socket
    |> cancel_async(:inventory)
    |> assign(loading: true, inventory: nil)
    |> start_async(:inventory, fn ->
      %{files: Workspace.list(root, directory), changes: Workspace.changes(root)}
    end)
  end

  defp load_preview(socket, selection) do
    root = socket.assigns.workspace

    socket
    |> cancel_async(:preview)
    |> assign(preview_loading: true, preview: nil, preview_error: nil, selection: selection)
    |> start_async(:preview, fn ->
      case selection do
        {:file, path} -> Workspace.preview(root, path)
        {:diff, path, area} -> Workspace.diff(root, path, area)
      end
    end)
  end

  def handle_async(:inventory, {:ok, inventory}, socket),
    do: {:noreply, assign(socket, loading: false, inventory: inventory)}

  def handle_async(:preview, {:ok, {:ok, preview}}, socket),
    do: {:noreply, assign(socket, preview_loading: false, preview: preview, preview_error: nil)}

  def handle_async(:preview, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, preview_loading: false, preview: nil, preview_error: error)}

  def handle_async(_, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:inventory, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         loading: false,
         inventory: %{
           files: {:error, "Unable to read files. Refresh to try again."},
           changes: {:error, "Unable to read Git changes."}
         }
       )}

  def handle_async(:preview, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         preview_loading: false,
         preview: nil,
         preview_error: "Unable to read this preview. Refresh to try again."
       )}

  defp entries({:ok, data}), do: data.entries
  defp entries(_), do: []
  defp failure({:error, error}), do: error
  defp failure(_), do: nil
  defp truncated?({:ok, data}), do: data.truncated
  defp truncated?(_), do: false
  defp parent(path), do: if(Path.dirname(path) == ".", do: "", else: Path.dirname(path))
  defp diff_class("+" <> _), do: "added"
  defp diff_class("-" <> _), do: "removed"
  defp diff_class("@@" <> _), do: "hunk"
  defp diff_class(_), do: "context"
  defp change_label("M"), do: "modified"
  defp change_label("A"), do: "added"
  defp change_label("D"), do: "deleted"
  defp change_label("U"), do: "conflict"
  defp change_label("T"), do: "type changed"
  defp change_label(code), do: code

  def render(assigns) do
    ~H"""
    <section id={@id} class="file-panel" aria-label="Workspace files and changes">
      <div class="panel-heading">
        <h2>Workspace</h2>
        <button id="refresh-files" phx-click="refresh" phx-target={@myself} disabled={@loading}>
          Refresh
        </button>
      </div>
      <p class="file-note">
        Current files shared by all sessions in this workspace. Refreshes after an agent turn finishes.
      </p>
      <p :if={@loading} role="status" class="muted">Reading workspace…</p>
      <section
        :if={@selection}
        id="file-preview"
        phx-hook="FilePreview"
        data-selection={inspect(@selection)}
        tabindex="-1"
        class="file-preview"
        aria-label="File preview"
        aria-busy={to_string(@preview_loading)}
      >
        <div class="preview-heading">
          <strong>{elem(@selection, 1)}</strong>
          <button phx-click="close_preview" phx-target={@myself} aria-label="Close preview">×</button>
        </div>
        <p :if={@preview_loading} role="status" class="file-notice">Loading preview…</p>
        <p :if={@preview_error} role="alert" class="file-notice">{@preview_error}</p>
        <div :if={@preview}>
          <div :if={@preview.kind == :image} class="image-preview">
            <img src={@preview.content} alt={@preview.path} />
          </div>
          <div :if={@preview.kind == :text}>
            <p class="file-note">Source · {byte_size(@preview.content)} bytes</p>
            <p :if={@preview.content == ""} class="file-notice">Empty file.</p>
            <pre class="source-preview"><code>{@preview.content}</code></pre>
          </div>
          <div :if={@preview.kind == :diff}>
            <p class="file-note">
              {if @preview.area == "staged",
                do: "Staged changes · index vs HEAD",
                else: "Unstaged changes · files vs index"}
            </p>
            <p :if={@preview.content == ""} class="file-notice">
              No changes in this comparison. Refresh to update the file list.
            </p>
            <pre class="diff-preview"><code><span :for={line <- String.split(@preview.content, "\n")} class={diff_class(line)}>{line}{"\n"}</span></code></pre>
          </div>
        </div>
      </section>
      <div :if={@inventory}>
        <section class="changes-section" aria-label="Git changes">
          <h3>Git changes <span>{length(entries(@inventory.changes))}</span></h3>
          <p class="file-note">Staged: index vs HEAD · Unstaged: files vs index</p>
          <p :if={failure(@inventory.changes)} class="file-notice">{failure(@inventory.changes)}</p>
          <p
            :if={is_nil(failure(@inventory.changes)) and entries(@inventory.changes) == []}
            class="file-notice"
          >
            Working tree is clean.
          </p>
          <p :if={truncated?(@inventory.changes)} class="file-notice">
            Showing the first 500 changed paths.
          </p>
          <div class="change-list">
            <div :for={change <- entries(@inventory.changes)} class="change-row">
              <button
                class="file-name"
                phx-click="preview"
                phx-target={@myself}
                phx-value-path={change.path}
                title={"Preview " <> change.path}
              >
                {change.path}
              </button>
              <div class="change-actions">
                <span :if={change.untracked} class="change-tag">Untracked</span>
                <button
                  :if={not change.untracked and change.staged != " "}
                  phx-click="diff"
                  phx-target={@myself}
                  phx-value-path={change.path}
                  phx-value-area="staged"
                >
                  Staged · {change_label(change.staged)}
                </button>
                <button
                  :if={not change.untracked and change.working != " "}
                  phx-click="diff"
                  phx-target={@myself}
                  phx-value-path={change.path}
                  phx-value-area="working"
                >
                  Unstaged · {change_label(change.working)}
                </button>
              </div>
            </div>
          </div>
        </section>
        <section class="files-section" aria-label="Browse files">
          <h3>Files</h3>
          <div class="file-breadcrumb">
            <button
              phx-click="browse"
              phx-target={@myself}
              phx-value-path=""
              aria-label="Workspace root"
            >
              Root
            </button>
            <button
              :if={@directory != ""}
              phx-click="browse"
              phx-target={@myself}
              phx-value-path={parent(@directory)}
              aria-label="Parent folder"
            >
              ↑ Up
            </button>
            <code>{@directory || ""}</code>
          </div>
          <p :if={failure(@inventory.files)} class="file-notice" role="alert">
            {failure(@inventory.files)}
          </p>
          <p
            :if={is_nil(failure(@inventory.files)) and entries(@inventory.files) == []}
            class="file-notice"
          >
            This folder is empty.
          </p>
          <p :if={truncated?(@inventory.files)} class="file-notice">
            Showing the first 500 entries by name.
          </p>
          <div class="file-list">
            <button
              :for={file <- entries(@inventory.files)}
              class="file-entry"
              phx-click={if file.type == :directory, do: "browse", else: "preview"}
              phx-target={@myself}
              phx-value-path={file.path}
              disabled={file.type not in [:regular, :directory]}
            >
              <span class="file-icon">{if file.type == :directory, do: "▸", else: "·"}</span>
              <span>{file.name}</span>
              <small>
                {if file.type == :directory,
                  do: "folder",
                  else: if(file.type != :regular, do: file.type)}
              </small>
            </button>
          </div>
        </section>
      </div>
    </section>
    """
  end
end
