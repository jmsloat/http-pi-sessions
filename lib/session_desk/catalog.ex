defmodule SessionDesk.Catalog do
  @moduledoc "SQLite metadata and serialized ownership of one agent process per workspace."
  use GenServer
  alias Exqlite.Sqlite3, as: DB
  alias SessionDesk.Session

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  def list(server \\ __MODULE__), do: GenServer.call(server, :list)
  def get(id, server \\ __MODULE__), do: GenServer.call(server, {:get, id})

  def add_workspace(name, path, server \\ __MODULE__),
    do: GenServer.call(server, {:workspace, name, path})

  def create_session(workspace, title, server \\ __MODULE__),
    do: GenServer.call(server, {:create, workspace, title})

  def rename(id, title, server \\ __MODULE__), do: GenServer.call(server, {:rename, id, title})

  def archive(id, archived, server \\ __MODULE__),
    do: GenServer.call(server, {:archive, id, archived})

  def activate(id, server \\ __MODULE__), do: GenServer.call(server, {:activate, id}, 15_000)
  def suspend(id, server \\ __MODULE__), do: GenServer.call(server, {:suspend, id}, 15_000)
  def subscribe, do: Phoenix.PubSub.subscribe(SessionDesk.PubSub, "catalog")
  def changed(server, id, pid, view), do: GenServer.cast(server, {:state, id, pid, view})

  def init(opts) do
    Process.flag(:trap_exit, true)
    root = opts[:root] || Application.fetch_env!(:session_desk, :data_dir)
    mode = opts[:mode] || Application.fetch_env!(:session_desk, :mode)
    File.mkdir_p!(root)
    {:ok, db} = DB.open(Path.join(root, "catalog.sqlite3"))

    :ok =
      DB.execute(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")

    migrate(db)
    state = %{db: db, root: root, mode: mode, active: %{}, monitors: %{}}
    bootstrap(state, opts[:workspace] || Application.fetch_env!(:session_desk, :workspace))
    # A restart never resumes a run or repeats a prompt automatically.
    sql(
      db,
      "UPDATE sessions SET status = CASE WHEN status IN ('working','waiting','stopping','starting','settling','configuring') THEN 'interrupted' ELSE 'suspended' END WHERE archived=0",
      []
    )

    {:ok, state}
  end

  defp migrate(db) do
    case sql(db, "PRAGMA user_version", []) do
      [[0]] ->
        :ok =
          DB.execute(db, """
          BEGIN IMMEDIATE;
          CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE, identity TEXT NOT NULL UNIQUE);
          CREATE TABLE sessions (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id),
            title TEXT NOT NULL, mode TEXT NOT NULL, file TEXT NOT NULL UNIQUE, archived INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'suspended', provider TEXT, model TEXT, thinking TEXT,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
          CREATE INDEX sessions_workspace ON sessions(workspace_id, mode, updated_at);
          PRAGMA user_version=1;
          COMMIT;
          """)

      [[1]] ->
        :ok

      _ ->
        raise "Catalog was created by a newer Session Desk version."
    end
  end

  defp bootstrap(s, path) do
    id = "#{s.mode}-main"

    if session(s, id) == nil do
      case workspace_identity(path) do
        {:ok, path, identity} ->
          workspace =
            case sql(s.db, "SELECT id FROM workspaces WHERE identity=? OR path=?", [
                   identity,
                   path
                 ]) do
              [[id]] ->
                id

              [] ->
                id = new_id()

                sql(s.db, "INSERT INTO workspaces VALUES (?,?,?,?)", [
                  id,
                  Path.basename(path),
                  path,
                  identity
                ])

                id
            end

          file =
            Path.join(s.root, if(s.mode == "demo", do: "demo.json", else: "pi-session.jsonl"))

          insert_session(s, id, workspace, "First session", file)

        {:error, error} ->
          raise error
      end
    end
  end

  def handle_call(:list, _, s) do
    workspaces =
      sql(s.db, "SELECT id,name,path FROM workspaces ORDER BY name", [])
      |> Enum.map(fn [id, name, path] -> %{id: id, name: name, path: path} end)

    sessions = session_rows(s, "WHERE s.mode=? ORDER BY s.updated_at DESC, s.id", [s.mode])
    {:reply, %{workspaces: workspaces, sessions: sessions}, s}
  end

  def handle_call({:get, id}, _, s), do: {:reply, session(s, id), s}

  def handle_call({:workspace, name, path}, _, s) do
    with :ok <- title_valid(name), {:ok, path, identity} <- workspace_identity(path) do
      case sql(s.db, "SELECT id FROM workspaces WHERE identity=? OR path=?", [identity, path]) do
        [] ->
          id = new_id()

          sql(s.db, "INSERT INTO workspaces VALUES (?,?,?,?)", [
            id,
            String.trim(name),
            path,
            identity
          ])

          notify()
          {:reply, {:ok, id}, s}

        _ ->
          {:reply,
           {:error, "That directory is already registered (possibly through another path)."}, s}
      end
    else
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:create, workspace, title}, _, s) do
    with :ok <- title_valid(title),
         [[_]] <- sql(s.db, "SELECT id FROM workspaces WHERE id=?", [workspace]) do
      id = new_id()

      file =
        Path.join([
          s.root,
          "sessions",
          s.mode,
          id <> if(s.mode == "demo", do: ".json", else: ".jsonl")
        ])

      insert_session(s, id, workspace, String.trim(title), file)
      notify()
      {:reply, {:ok, id}, s}
    else
      {:error, _} = error -> {:reply, error, s}
      _ -> {:reply, {:error, "Workspace no longer exists."}, s}
    end
  end

  def handle_call({:rename, id, title}, _, s) do
    with %{id: ^id} <- session(s, id), :ok <- title_valid(title) do
      sql(s.db, "UPDATE sessions SET title=?, updated_at=? WHERE id=?", [
        String.trim(title),
        now(),
        id
      ])

      notify()
      {:reply, :ok, s}
    else
      {:error, _} = error -> {:reply, error, s}
      _ -> {:reply, {:error, "Session not found."}, s}
    end
  end

  def handle_call({:archive, id, archived}, _, s) when is_boolean(archived) do
    with %{id: ^id} <- session(s, id), {:ok, s} <- stop_idle(s, id) do
      sql(s.db, "UPDATE sessions SET archived=?, status='suspended', updated_at=? WHERE id=?", [
        if(archived, do: 1, else: 0),
        now(),
        id
      ])

      notify()
      {:reply, :ok, s}
    else
      {:error, error} -> {:reply, {:error, error}, s}
      _ -> {:reply, {:error, "Session not found."}, s}
    end
  end

  def handle_call({:suspend, id}, _, s) do
    case stop_idle(s, id) do
      {:ok, s} ->
        notify()
        {:reply, :ok, s}

      {:error, error} ->
        {:reply, {:error, error}, s}
    end
  end

  def handle_call({:activate, id}, _, s) do
    record = session(s, id)

    cond do
      record == nil ->
        {:reply, {:error, "Session not found."}, s}

      record.archived ->
        {:reply, {:error, "Restore this archived session first."}, s}

      Map.has_key?(s.active, id) ->
        {:reply, {:ok, s.active[id]}, s}

      not File.dir?(record.path) ->
        {:reply, {:error, "Workspace directory is unavailable. Check its mount."}, s}

      true ->
        other =
          Enum.find(Map.keys(s.active), fn active_id ->
            session(s, active_id).workspace_id == record.workspace_id
          end)

        case stop_idle(s, other) do
          {:error, _} ->
            {:reply,
             {:error,
              "Another session is working in this workspace. Stop it or wait for it to finish."},
             s}

          {:ok, s} ->
            options = [
              id: id,
              workspace: record.path,
              session_file: record.file,
              mode: s.mode,
              catalog: self(),
              preferences: record
            ]

            case DynamicSupervisor.start_child(SessionDesk.SessionSupervisor, {Session, options}) do
              {:ok, pid} ->
                ref = Process.monitor(pid)

                sql(s.db, "UPDATE sessions SET status='starting', updated_at=? WHERE id=?", [
                  now(),
                  id
                ])

                notify()

                {:reply, {:ok, pid},
                 %{s | active: Map.put(s.active, id, pid), monitors: Map.put(s.monitors, ref, id)}}

              {:error, reason} ->
                {:reply, {:error, "Could not start session: #{inspect(reason)}"}, s}
            end
        end
    end
  end

  def handle_cast({:state, id, pid, view}, s) do
    if s.active[id] == pid do
      sql(
        s.db,
        "UPDATE sessions SET status=?,provider=COALESCE(?,provider),model=COALESCE(?,model),thinking=COALESCE(?,thinking) WHERE id=?",
        [
          Atom.to_string(view.status),
          view.provider,
          view.model,
          view.thinking,
          id
        ]
      )

      notify()
    end

    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    {id, monitors} = Map.pop(s.monitors, ref)

    if id && s.active[id] == pid do
      sql(s.db, "UPDATE sessions SET status='interrupted' WHERE id=?", [id])
      notify()
      {:noreply, %{s | monitors: monitors, active: Map.delete(s.active, id)}}
    else
      {:noreply, %{s | monitors: monitors}}
    end
  end

  def terminate(_, s) do
    Enum.each(s.active, fn {_, pid} ->
      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(SessionDesk.SessionSupervisor, pid)
    end)

    DB.close(s.db)
  end

  defp stop_idle(s, nil), do: {:ok, s}

  defp stop_idle(s, id) do
    case s.active[id] do
      nil ->
        {:ok, s}

      pid ->
        result =
          try do
            Session.command(:suspend, id)
          catch
            :exit, _ -> {:ok, nil}
          end

        case result do
          {:ok, view} ->
            # Wait for termination before another process can own this workspace.
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              5000 -> exit(:session_shutdown_timeout)
            end

            if view do
              sql(
                s.db,
                "UPDATE sessions SET status='suspended',provider=COALESCE(?,provider),model=COALESCE(?,model),thinking=COALESCE(?,thinking) WHERE id=?",
                [view.provider, view.model, view.thinking, id]
              )
            else
              sql(s.db, "UPDATE sessions SET status='suspended' WHERE id=?", [id])
            end

            Phoenix.PubSub.broadcast(SessionDesk.PubSub, "session:" <> id, {:session_closed, id})
            {:ok, %{s | active: Map.delete(s.active, id)}}

          error ->
            error
        end
    end
  end

  defp session(s, id), do: List.first(session_rows(s, "WHERE s.id=? AND s.mode=?", [id, s.mode]))

  defp session_rows(s, suffix, params) do
    sql(
      s.db,
      "SELECT s.id,s.workspace_id,s.title,s.mode,s.file,s.archived,s.status,s.provider,s.model,s.thinking,w.path,w.name FROM sessions s JOIN workspaces w ON w.id=s.workspace_id " <>
        suffix,
      params
    )
    |> Enum.map(fn [
                     id,
                     workspace,
                     title,
                     mode,
                     file,
                     archived,
                     status,
                     provider,
                     model,
                     thinking,
                     path,
                     name
                   ] ->
      %{
        id: id,
        workspace_id: workspace,
        title: title,
        mode: mode,
        file: file,
        archived: archived == 1,
        status: status,
        provider: provider,
        model: model,
        thinking: thinking,
        path: path,
        workspace_name: name
      }
    end)
  end

  defp insert_session(s, id, workspace, title, file) do
    sql(
      s.db,
      "INSERT INTO sessions(id,workspace_id,title,mode,file,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
      [id, workspace, title, s.mode, file, now(), now()]
    )
  end

  defp workspace_identity(path) when is_binary(path) do
    path = Path.expand(path)

    case File.stat(path) do
      {:ok, %{type: :directory} = stat} ->
        {:ok, path, "#{stat.major_device}:#{stat.minor_device}:#{stat.inode}"}

      _ ->
        {:error, "Enter an existing directory visible to the server."}
    end
  end

  defp workspace_identity(_), do: {:error, "Enter a directory path."}

  defp title_valid(title) when is_binary(title) do
    if String.trim(title) != "" and String.length(title) <= 100,
      do: :ok,
      else: {:error, "Use a name between 1 and 100 characters."}
  end

  defp title_valid(_), do: {:error, "Enter a name."}
  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp now, do: System.system_time(:millisecond)
  defp notify, do: Phoenix.PubSub.broadcast(SessionDesk.PubSub, "catalog", :catalog_changed)

  defp sql(db, query, params) do
    {:ok, statement} = DB.prepare(db, query)

    try do
      :ok = DB.bind(statement, params)
      {:ok, rows} = DB.fetch_all(db, statement)
      rows
    after
      DB.release(db, statement)
    end
  end
end
