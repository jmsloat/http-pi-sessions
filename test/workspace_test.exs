defmodule SessionDesk.WorkspaceTest do
  use ExUnit.Case, async: true
  alias SessionDesk.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "desk-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "browses directories and reads bounded text, images, and empty files", %{root: root} do
    File.mkdir_p!(Path.join(root, "nested"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "nested/note.md"), "# Hi\n<script>alert(1)</script>")
    File.write!(Path.join(root, "empty"), "")
    png = <<137, "PNG\r\n", 26, 10, 0, 0>>
    File.write!(Path.join(root, "picture.png"), png)
    assert {:ok, %{entries: entries}} = Workspace.list(root)
    assert hd(entries).name == "nested"
    refute Enum.any?(entries, &(&1.name == ".git"))

    assert {:ok, %{kind: :text, content: "# Hi\n<script>alert(1)</script>"}} =
             Workspace.preview(root, "nested/note.md")

    assert {:ok, %{content: ""}} = Workspace.preview(root, "empty")
    assert {:ok, %{kind: :image, content: content}} = Workspace.preview(root, "picture.png")
    assert content == "data:image/png;base64," <> Base.encode64(png)
    File.write!(Path.join(root, "binary"), <<0, 255>>)
    assert {:error, "Binary file." <> _} = Workspace.preview(root, "binary")
    File.write!(Path.join(root, "large"), String.duplicate("a", 262_145))
    assert {:error, "File is too large" <> _} = Workspace.preview(root, "large")
    File.write!(Path.join(root, "text.png"), String.duplicate("a", 262_145))
    assert {:error, "File is too large" <> _} = Workspace.preview(root, "text.png")
    for n <- 1..501, do: File.write!(Path.join(root, "nested/#{n}"), "")
    assert {:ok, %{entries: entries, truncated: true}} = Workspace.list(root, "nested")
    assert length(entries) == 500
  end

  test "rejects traversal, symlinks, Git internals and special files", %{root: root} do
    File.mkdir_p!(Path.join(root, "nested"))
    File.ln_s!(System.tmp_dir!(), Path.join(root, "outside"))
    System.cmd("mkfifo", [Path.join(root, "pipe")])

    for path <- [
          "../escape",
          "/etc/passwd",
          "nested/../../escape",
          ".git/config",
          "outside",
          "outside/missing",
          "pipe",
          <<0>>
        ] do
      assert {:error, _} = Workspace.preview(root, path)
      assert {:error, _} = Workspace.diff(root, path, "working")
    end

    assert {:error, _} = Workspace.list(root, "outside")
    assert {:error, "This path no longer exists." <> _} = Workspace.preview(root, "missing")
    assert {:error, "Workspace directory is missing" <> _} = Workspace.list(root <> "/missing")
  end

  test "separates staged, unstaged, deleted and untracked paths including unusual names", %{
    root: root
  } do
    init(root)

    for path <- ["both.txt", "deleted.txt", "a [1].txt", "other.txt", "line\nbreak.txt"],
        do: File.write!(Path.join(root, path), "original\n")

    git(root, ["add", "."])
    git(root, ["commit", "-qm", "baseline"])
    File.write!(Path.join(root, "both.txt"), "staged\n")
    git(root, ["add", "both.txt"])
    File.write!(Path.join(root, "both.txt"), "working\n")
    File.rm!(Path.join(root, "deleted.txt"))
    File.write!(Path.join(root, "new.txt"), "untracked\n")
    File.write!(Path.join(root, "a [1].txt"), "literal filename\n")
    File.write!(Path.join(root, "other.txt"), "must not appear in literal diff\n")
    File.write!(Path.join(root, "line\nbreak.txt"), "newline filename\n")
    assert {:ok, %{entries: entries}} = Workspace.changes(root)

    assert Enum.find(entries, &(&1.path == "both.txt")) == %{
             path: "both.txt",
             staged: "M",
             working: "M",
             untracked: false
           }

    assert Enum.find(entries, &(&1.path == "new.txt")).untracked
    assert Enum.find(entries, &(&1.path == "line\nbreak.txt"))
    assert {:ok, %{content: staged}} = Workspace.diff(root, "both.txt", "staged")
    assert staged =~ "+staged"
    refute staged =~ "+working"
    assert {:ok, %{content: working}} = Workspace.diff(root, "both.txt", "working")
    assert working =~ "-staged"
    assert working =~ "+working"
    assert {:ok, %{content: deleted}} = Workspace.diff(root, "deleted.txt", "working")
    assert deleted =~ "deleted file mode"
    assert {:ok, %{content: literal}} = Workspace.diff(root, "a [1].txt", "working")
    assert literal =~ "+literal filename"
    refute literal =~ "must not appear"
  end

  test "supports unborn repositories and confines nested workspaces to their subtree", %{
    root: root
  } do
    init(root)
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "sub/new.txt"), "nested\n")
    File.write!(Path.join(root, "outside.txt"), "outside\n")
    git(root, ["add", "."])

    assert {:ok, %{entries: [%{path: "new.txt", staged: "A"}]}} =
             Workspace.changes(Path.join(root, "sub"))

    assert {:ok, %{content: diff}} = Workspace.diff(Path.join(root, "sub"), "new.txt", "staged")
    assert diff =~ "+nested"
    refute diff =~ "outside"
    assert {:ok, %{content: ""}} = Workspace.diff(root, "outside.txt", "working")
  end

  test "disables external diff and textconv and does not modify the index", %{root: root} do
    init(root)
    File.write!(Path.join(root, "file.txt"), "before\n")
    File.write!(Path.join(root, ".gitattributes"), "*.txt diff=custom\n")
    git(root, ["add", "."])
    git(root, ["commit", "-qm", "baseline"])
    git(root, ["config", "diff.external", "touch external-ran"])
    git(root, ["config", "diff.custom.textconv", "touch textconv-ran"])
    git(root, ["config", "core.fsmonitor", "touch monitor-ran"])
    index = File.read!(Path.join(root, ".git/index"))
    File.write!(Path.join(root, "file.txt"), "after\n")
    assert {:ok, _} = Workspace.changes(root)
    assert {:ok, %{content: diff}} = Workspace.diff(root, "file.txt", "working")
    assert diff =~ "+after"

    for name <- ["external-ran", "textconv-ran", "monitor-ran"],
        do: refute(File.exists?(Path.join(root, name)))

    assert File.read!(Path.join(root, ".git/index")) == index
  end

  test "bounds Git output and remains usable after rejecting an oversized diff", %{root: root} do
    init(root)
    File.write!(Path.join(root, "file.txt"), "before\n")
    git(root, ["add", "."])
    git(root, ["commit", "-qm", "baseline"])
    File.write!(Path.join(root, "file.txt"), String.duplicate("large diff line\n", 100_000))
    assert {:error, "Git output exceeds" <> _} = Workspace.diff(root, "file.txt", "working")
    assert {:ok, _} = Workspace.changes(root)
    File.write!(Path.join(root, "file.txt"), String.duplicate("a\n", 5_001))

    assert {:error, "This diff exceeds 5,000 lines." <> _} =
             Workspace.diff(root, "file.txt", "working")

    File.write!(Path.join(root, "file.txt"), "small again\n")
    assert {:ok, %{content: diff}} = Workspace.diff(root, "file.txt", "working")
    assert diff =~ "+small again"
  end

  test "a non-repository still provides file browsing", %{root: root} do
    assert {:error, "This workspace is not a Git repository." <> _} = Workspace.changes(root)
    assert {:ok, %{entries: []}} = Workspace.list(root)
  end

  defp init(root) do
    git(root, ["init", "-q"])
    git(root, ["config", "user.email", "test@example.com"])
    git(root, ["config", "user.name", "Test"])
  end

  defp git(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
