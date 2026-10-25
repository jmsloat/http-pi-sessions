defmodule SessionDesk.CatalogTest do
  use ExUnit.Case, async: false
  alias SessionDesk.{Catalog, Session, History}

  setup do
    root = Path.join(System.tmp_dir!(), "desk-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    start_supervised!({Catalog, root: root, workspace: root, mode: "demo"})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, first: Catalog.get("demo-main")}
  end

  test "imports prototype history without starting a process; metadata survives reopening", %{
    root: root,
    first: first
  } do
    File.write!(
      first.file,
      Jason.encode!([%{"role" => "user", "content" => "Keep my conversation"}])
    )

    assert [%{text: "Keep my conversation"}] = History.load(first).messages
    assert Registry.lookup(SessionDesk.Registry, first.id) == []
    assert :ok = Catalog.rename(first.id, "Existing conversation")
    assert :ok = Catalog.archive(first.id, true)
    assert {:error, _} = Catalog.activate(first.id)
    stop_supervised!(Catalog)
    start_supervised!({Catalog, root: root, workspace: root, mode: "demo"})
    record = Catalog.get(first.id)
    assert record.title == "Existing conversation"
    assert record.archived
    assert File.exists?(record.file)
    assert :ok = Catalog.archive(first.id, false)
  end

  test "one active process per workspace, no cross-session history, and persisted model choices",
       %{first: first} do
    {:ok, second} = Catalog.create_session(first.workspace_id, "Second task")
    {:ok, pid} = Catalog.activate(first.id)
    wait(fn -> Session.snapshot(first.id).status == :idle end)
    assert :ok = Session.command({:set_thinking, "high"}, first.id)

    wait(fn ->
      Session.snapshot(first.id).status == :idle and Catalog.get(first.id).thinking == "high"
    end)

    assert :ok = Session.command({:set_model, "demo", "scripted-fast"}, first.id)

    wait(fn ->
      Catalog.get(first.id).model == "scripted-fast" and
        Session.snapshot(first.id).status == :idle
    end)

    assert :ok = Session.command({:prompt, "First task only"}, first.id)
    assert {:error, _} = Catalog.activate(second)
    assert {:error, _} = Catalog.archive(first.id, true)
    assert {:error, _} = Session.command({:set_model, "demo", "scripted-demo"}, first.id)
    assert :ok = Session.command(:abort, first.id)
    wait(fn -> Session.snapshot(first.id).status == :idle end)
    {:ok, _} = Catalog.activate(second)
    refute Process.alive?(pid)
    wait(fn -> Session.snapshot(second).status == :idle end)
    assert Session.snapshot(second).messages == []
    {:ok, _} = Catalog.activate(first.id)
    wait(fn -> Session.snapshot(first.id).status == :idle end)
    assert Session.snapshot(first.id).model == "scripted-fast"
    assert [%{text: "First task only", role: "user"}] = Session.snapshot(first.id).messages
  end

  test "validates workspaces and treats symlink aliases as the same directory", %{root: root} do
    assert {:error, _} = Catalog.add_workspace("Missing", Path.join(root, "missing"))
    assert {:error, _} = Catalog.add_workspace("Again", root)
    alias_path = Path.join(root, "alias")
    File.ln_s!(root, alias_path)
    assert {:error, _} = Catalog.add_workspace("Alias", alias_path)
    other = Path.join(root, "other")
    File.mkdir!(other)
    assert {:ok, _} = Catalog.add_workspace("Other", other)
    assert {:error, _} = Catalog.create_session("unknown", "Task")
    assert {:error, _} = Catalog.rename("demo-main", " ")
  end

  test "different workspaces may run together", %{root: root, first: first} do
    other = Path.join(root, "other")
    File.mkdir!(other)
    {:ok, workspace} = Catalog.add_workspace("Other", other)
    {:ok, id} = Catalog.create_session(workspace, "Other task")
    {:ok, pid1} = Catalog.activate(first.id)
    {:ok, pid2} = Catalog.activate(id)

    wait(fn ->
      Session.snapshot(first.id).status == :idle and Session.snapshot(id).status == :idle
    end)

    assert Process.alive?(pid1) and Process.alive?(pid2)
  end

  test "interrupted runs are recorded but never relaunched after restart", %{
    root: root,
    first: first
  } do
    {:ok, _} = Catalog.activate(first.id)
    wait(fn -> Session.snapshot(first.id).status == :idle end)
    Session.command({:prompt, "Do not replay"}, first.id)

    wait(fn ->
      Catalog.get(first.id).status == "working" and Session.snapshot(first.id).messages != []
    end)

    stop_supervised!(Catalog)
    start_supervised!({Catalog, root: root, workspace: root, mode: "demo"})
    assert Catalog.get(first.id).status == "interrupted"
    assert Registry.lookup(SessionDesk.Registry, first.id) == []
    assert Enum.count(History.load(Catalog.get(first.id)).messages, &(&1.role == "user")) == 1
  end

  defp wait(fun, tries \\ 250)
  defp wait(_, 0), do: flunk("Condition did not become true")

  defp wait(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(30)
          wait(fun, tries - 1)
        )
  end
end
