defmodule SessionDesk.PiIntegrationTest do
  use ExUnit.Case, async: false
  alias SessionDesk.Session
  @runtime System.get_env("PI_TEST_RUNTIME")

  @tag skip: is_nil(@runtime)
  test "Elixir controller drives real Pi and Gentle, answers a question and resumes persisted history" do
    runtime = Path.expand(@runtime)
    root = Path.join(System.tmp_dir!(), "desk-real-pi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    provider = Path.join(runtime, "desk-test-provider.ts")
    File.cp!("test/support/deterministic-provider.ts", provider)
    gentle = Path.join(runtime, "node_modules/gentle-pi/extensions")
    pi = Path.join(runtime, "node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")

    args = [
      pi,
      "--mode",
      "rpc",
      "--session",
      Path.join(root, "session.jsonl"),
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "-e",
      Path.join(gentle, "gentle-todo.ts"),
      "-e",
      Path.join(gentle, "ask-user-question.ts"),
      "-e",
      provider,
      "--provider",
      "desk-test",
      "--model",
      "deterministic"
    ]

    id = "real-pi"

    pid =
      start_supervised!(
        {Session,
         id: id,
         command: {System.find_executable("node"), args},
         workspace: root,
         env: [{"PI_CODING_AGENT_DIR", Path.join(root, "home")}]}
      )

    wait_until(fn -> Session.snapshot(id).status == :idle end)
    assert Enum.any?(Session.snapshot(id).models, &(&1["id"] == "deterministic-reasoning"))
    assert :ok = Session.command({:set_model, "desk-test", "deterministic-reasoning"}, id)

    wait_until(fn ->
      Session.snapshot(id).status == :idle and
        Session.snapshot(id).model == "deterministic-reasoning"
    end)

    assert :ok = Session.command({:set_thinking, "high"}, id)

    wait_until(fn ->
      Session.snapshot(id).status == :idle and Session.snapshot(id).thinking == "high"
    end)

    assert :ok = Session.command({:prompt, "Run the deterministic integration check"}, id)
    wait_until(fn -> Session.snapshot(id).status == :waiting end)
    view = Session.snapshot(id)
    assert length(view.tasks) == 3
    assert hd(view.tasks)["status"] == "in_progress"
    q = hd(view.questions)
    assert q["title"] =~ "Can you see the real Gentle Todo list?"
    assert :ok = Session.command({:answer, q["id"], %{"value" => "Yes"}}, id)
    wait_until(fn -> Session.snapshot(id).status == :idle end)
    assert Enum.all?(Session.snapshot(id).tasks, &(&1["status"] == "done"))
    assert List.last(Session.snapshot(id).messages).text =~ "real Pi runtime"
    assert :ok = :exec.kill(:sys.get_state(pid).os_pid, 9)
    wait_until(fn -> Session.snapshot(id).status == :interrupted end)
    assert :ok = Session.command(:restart, id)
    wait_until(fn -> Session.snapshot(id).status == :idle end)
    view = Session.snapshot(id)
    assert Enum.count(view.messages, &(&1.role == "user")) == 1
    assert List.last(view.messages).text =~ "real Pi runtime"
    assert view.tasks == []
    assert view.questions == []
  end

  @tag skip: is_nil(@runtime)
  test "managed live sessions retain model and thinking choices across process and catalog restarts" do
    runtime = Path.expand(@runtime)
    root = Path.join(System.tmp_dir!(), "desk-managed-pi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    provider = Path.join(runtime, "desk-managed-test-provider.ts")
    File.cp!("test/support/deterministic-provider.ts", provider)

    old =
      for key <- [:pi_executable, :pi_args, :pi_home],
          into: %{},
          do: {key, Application.get_env(:session_desk, key)}

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if value,
          do: Application.put_env(:session_desk, key, value),
          else: Application.delete_env(:session_desk, key)
      end)

      File.rm_rf!(root)
    end)

    Application.put_env(:session_desk, :pi_executable, Path.join(runtime, "node_modules/.bin/pi"))
    Application.put_env(:session_desk, :pi_home, Path.join(root, "home"))

    Application.put_env(:session_desk, :pi_args, [
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "-e",
      provider,
      "--provider",
      "desk-test",
      "--model",
      "deterministic"
    ])

    alias SessionDesk.Catalog
    start_supervised!({Catalog, root: root, workspace: root, mode: "live"})
    {:ok, pid} = Catalog.activate("live-main")
    wait_until(fn -> Session.snapshot("live-main").status == :idle end)

    assert :ok =
             Session.command({:set_model, "desk-test", "deterministic-reasoning"}, "live-main")

    wait_until(fn ->
      Session.snapshot("live-main").status == :idle and
        Session.snapshot("live-main").model == "deterministic-reasoning"
    end)

    assert :ok = Session.command({:set_thinking, "high"}, "live-main")

    wait_until(fn ->
      Session.snapshot("live-main").status == :idle and
        Catalog.get("live-main").thinking == "high"
    end)

    assert :ok = :exec.kill(:sys.get_state(pid).os_pid, 9)
    wait_until(fn -> Session.snapshot("live-main").status == :interrupted end)
    assert :ok = Session.command(:restart, "live-main")
    wait_until(fn -> Session.snapshot("live-main").status == :idle end)
    assert Session.snapshot("live-main").model == "deterministic-reasoning"
    assert Session.snapshot("live-main").thinking == "high"
    stop_supervised!(Catalog)
    start_supervised!({Catalog, root: root, workspace: root, mode: "live"})
    assert Registry.lookup(SessionDesk.Registry, "live-main") == []
    {:ok, _} = Catalog.activate("live-main")
    wait_until(fn -> Session.snapshot("live-main").status == :idle end)
    assert Session.snapshot("live-main").model == "deterministic-reasoning"
    assert Session.snapshot("live-main").thinking == "high"
    assert Session.snapshot("live-main").messages == []
  end

  defp wait_until(fun, tries \\ 400)
  defp wait_until(_, 0), do: flunk("Real Pi did not reach expected state")

  defp wait_until(fun, tries),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(40)
            wait_until(fun, tries - 1)
          )
      )
end
