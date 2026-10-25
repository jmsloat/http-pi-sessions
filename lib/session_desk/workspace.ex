defmodule SessionDesk.Workspace do
  @moduledoc "Bounded, read-only workspace browsing and Git inspection."
  @text_limit 262_144
  @image_limit 2_097_152
  @command_limit 1_048_576
  @entry_limit 500

  def list(root, relative \\ "") do
    with {:ok, path} <- resolve(root, relative),
         {:ok, names} <- File.ls(path) do
      entries =
        names
        |> Enum.reject(&(&1 == ".git" or not String.valid?(&1)))
        |> Enum.sort()
        |> Enum.take(@entry_limit + 1)
        |> Enum.map(fn name ->
          type =
            case File.lstat(Path.join(path, name)) do
              {:ok, stat} -> stat.type
              _ -> :unavailable
            end

          %{name: name, path: join(relative, name), type: type}
        end)
        |> Enum.sort_by(&{&1.type != :directory, &1.name})

      {:ok,
       %{
         path: relative,
         entries: Enum.take(entries, @entry_limit),
         truncated: length(entries) > @entry_limit
       }}
    else
      {:error, reason} -> error(reason)
    end
  end

  def preview(root, relative) do
    with {:ok, path} <- resolve(root, relative),
         {:ok, %{type: :regular} = stat} <- File.lstat(path) do
      mime = image_type(Path.extname(path) |> String.downcase())
      limit = if mime, do: @image_limit, else: @text_limit

      with true <- stat.size <= limit,
           {:ok, content} <- read_bounded(path, limit) do
        cond do
          mime && image_signature?(mime, content) ->
            {:ok,
             %{
               kind: :image,
               path: relative,
               size: byte_size(content),
               content: "data:#{mime};base64," <> Base.encode64(content)
             }}

          text?(content) and byte_size(content) <= @text_limit ->
            {:ok, %{kind: :text, path: relative, size: byte_size(content), content: content}}

          text?(content) ->
            {:error, "File is too large to preview (256 KiB text / 2 MiB images)."}

          true ->
            {:error,
             "Binary file. Preview supports UTF-8 text and PNG, JPEG, GIF, or WebP images."}
        end
      else
        false -> {:error, "File is too large to preview (256 KiB text / 2 MiB images)."}
        {:error, reason} -> error(reason)
      end
    else
      {:ok, _} -> {:error, "Only regular files can be previewed."}
      {:error, reason} -> error(reason)
    end
  end

  def changes(root) do
    with {:ok, _} <- resolve(root, ""),
         {:ok, prefix} <- git(root, ["rev-parse", "--show-prefix"]),
         {:ok, output} <-
           git(root, [
             "status",
             "--porcelain=v1",
             "-z",
             "--no-renames",
             "--untracked-files=all",
             "--ignore-submodules=all",
             "--",
             "."
           ]) do
      prefix = String.trim_trailing(prefix, "\n")

      entries =
        output
        |> String.split(<<0>>, trim: true)
        |> Stream.flat_map(fn
          <<x, y, 32, path::binary>> ->
            if String.valid?(path) and String.starts_with?(path, prefix) do
              relative = binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix))
              [%{path: relative, staged: <<x>>, working: <<y>>, untracked: x == ??}]
            else
              []
            end

          _ ->
            []
        end)
        |> Enum.take(@entry_limit + 1)

      {:ok,
       %{entries: Enum.take(entries, @entry_limit), truncated: length(entries) > @entry_limit}}
    else
      {:error, reason} -> error(reason)
    end
  end

  def diff(root, relative, area) when area in ["staged", "working"] do
    # Deleted files have no final inode; their existing parent components must still be safe.
    with {:ok, _} <- resolve(root, relative, true),
         {:ok, output} <-
           git(
             root,
             [
               "diff",
               "--no-ext-diff",
               "--no-textconv",
               "--no-color",
               "--no-renames",
               "--relative",
               "--submodule=short",
               "--ignore-submodules=all"
             ] ++
               if(area == "staged", do: ["--cached"], else: []) ++ ["--", relative]
           ) do
      cond do
        not text?(output) ->
          {:error, "This diff contains non-UTF-8 data and cannot be displayed."}

        length(:binary.matches(output, "\n")) > 5_000 ->
          {:error, "This diff exceeds 5,000 lines. Inspect it in the terminal."}

        true ->
          {:ok, %{kind: :diff, path: relative, content: output, area: area}}
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  def diff(_, _, _), do: {:error, "Choose staged or unstaged changes."}

  # Refuse symlinks inside a workspace, special files, traversal and Git internals.
  # The registered root itself may be an intentional symlink (Catalog supports that).
  defp resolve(root, relative, missing \\ false)

  defp resolve(root, relative, missing) when is_binary(relative) do
    parts = String.split(relative, "/", trim: true)

    cond do
      not File.dir?(root) ->
        {:error, "Workspace directory is missing or unavailable."}

      not String.valid?(relative) or String.contains?(relative, <<0>>) or
        Path.type(relative) != :relative or Enum.any?(parts, &(&1 in ["..", ".git"])) ->
        {:error, "Choose a path inside this workspace, outside Git internals."}

      true ->
        Enum.reduce_while(parts, {:ok, Path.expand(root)}, fn part, {:ok, parent} ->
          path = Path.join(parent, part)

          case File.lstat(path) do
            {:ok, %{type: :symlink}} ->
              {:halt,
               {:error, "Symlink previews are disabled. Open the real file within its workspace."}}

            {:ok, %{type: type}} when type in [:regular, :directory] ->
              {:cont, {:ok, path}}

            {:ok, _} ->
              {:halt, {:error, "Special files cannot be opened."}}

            {:error, :enoent} when missing ->
              {:cont, {:ok, path}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp resolve(_, _, _), do: {:error, "Invalid workspace path."}
  defp join("", name), do: name
  defp join(parent, name), do: parent <> "/" <> name

  defp read_bounded(path, limit) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, limit + 1) end) do
      {:ok, :eof} ->
        {:ok, ""}

      {:ok, data} when is_binary(data) and byte_size(data) <= limit ->
        {:ok, data}

      {:ok, data} when is_binary(data) ->
        {:error, "File grew beyond the preview limit. Refresh to try again."}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp text?(data), do: String.valid?(data) and not String.contains?(data, <<0>>)
  defp image_type(".png"), do: "image/png"
  defp image_type(ext) when ext in [".jpg", ".jpeg"], do: "image/jpeg"
  defp image_type(".gif"), do: "image/gif"
  defp image_type(".webp"), do: "image/webp"
  defp image_type(_), do: nil
  defp image_signature?("image/png", <<137, "PNG\r\n", 26, 10, _::binary>>), do: true
  defp image_signature?("image/jpeg", <<255, 216, 255, _::binary>>), do: true

  defp image_signature?("image/gif", <<"GIF", version::binary-size(3), _::binary>>),
    do: version in ["87a", "89a"]

  defp image_signature?("image/webp", <<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: true
  defp image_signature?(_, _), do: false

  defp git(root, args) do
    case System.find_executable("git") do
      nil -> {:error, "Git is not installed on the server. File browsing is still available."}
      executable -> run_git(executable, root, args)
    end
  end

  defp run_git(executable, root, args) do
    previous = Process.flag(:trap_exit, true)
    # Do not inherit a GIT_DIR/GIT_WORK_TREE override from the host process.
    env = for {key, _} <- System.get_env(), String.starts_with?(key, "GIT_"), do: {key, false}
    env = env ++ [{"GIT_OPTIONAL_LOCKS", "0"}, {"GIT_TERMINAL_PROMPT", "0"}]

    options = [
      :stdout,
      :stderr,
      :kill_group,
      {:group, 0},
      {:kill_timeout, 0},
      {:cd, root},
      {:env, env}
    ]

    config = [
      "--no-pager",
      "--literal-pathspecs",
      "-c",
      "core.fsmonitor=false",
      "-c",
      "diff.autoRefreshIndex=false"
    ]

    try do
      case :exec.run_link([executable | config ++ args], options) do
        {:ok, pid, os_pid} ->
          try do
            collect(pid, os_pid, [], [], 0, System.monotonic_time(:millisecond) + 5_000)
          after
            Process.unlink(pid)
            :exec.stop(pid)

            receive do
              {:EXIT, ^pid, _} -> :ok
            after
              0 -> :ok
            end
          end

        {:error, _} ->
          {:error, "Unable to start Git in this workspace."}
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp collect(pid, os_pid, out, err, size, deadline) do
    receive do
      {stream, ^os_pid, data} when stream in [:stdout, :stderr] ->
        if size + byte_size(data) > @command_limit do
          {:error, "Git output exceeds 1 MiB. Inspect a smaller change in the terminal."}
        else
          collect(
            pid,
            os_pid,
            if(stream == :stdout, do: [data | out], else: out),
            if(stream == :stderr, do: [data | err], else: err),
            size + byte_size(data),
            deadline
          )
        end

      {:EXIT, ^pid, :normal} ->
        {:ok, out |> Enum.reverse() |> IO.iodata_to_binary()}

      {:EXIT, ^pid, _} ->
        detail = err |> Enum.reverse() |> IO.iodata_to_binary()

        if String.contains?(detail, "not a git repository"),
          do:
            {:error, "This workspace is not a Git repository. File browsing is still available."},
          else:
            {:error,
             "Git could not read this workspace. Check repository permissions and configuration."}

      {:EXIT, _, reason} ->
        exit(reason)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {:error, "Git took longer than 5 seconds. Refresh to try again."}
    end
  end

  defp error(reason) when is_binary(reason), do: {:error, reason}
  defp error(:enoent), do: {:error, "This path no longer exists. Refresh the workspace."}
  defp error(:enotdir), do: {:error, "This path is not a directory."}
  defp error(:eacces), do: {:error, "The app does not have permission to read this path."}
  defp error(reason), do: {:error, "Cannot read this path: #{:file.format_error(reason)}"}
end
