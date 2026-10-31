defmodule Mix.Tasks.Cloud.Typst.Install do
  @shortdoc "Installs the pinned Typst CLI used to render audit PDFs"

  @moduledoc """
  Downloads the pinned Typst release (#{Cloud.Typst.version()}, the official
  static `#{Cloud.Typst.asset()}` from GitHub), checks its SHA-256 against
  the checksum pinned in `Cloud.Typst`, extracts the `typst` binary to the
  configured path (`:cloud, :typst_path` from the compile-time config, else
  the app's `priv/bin/typst`, git-ignored)
  with mode 0755, and prints `typst --version`.

      mix cloud.typst.install [--force] [--archive PATH]

  The archive is downloaded with Req unless `--archive` names an already
  downloaded copy of the same asset (for builds without network access); its
  checksum is checked either way. An installed binary is left alone when it
  is the pinned one, and replaced only with `--force` when it is not.

  Extracting needs `tar` with xz support on the build host. Production builds
  run this same task at release build time, or put the binary in the
  container image and point `TYPST_PATH` at it (see the README).
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [force: :boolean, archive: :string])
    # compile-time config only: runtime.exs needs production secrets, and in a
    # release build the binary belongs in the app's own priv/bin
    Mix.Task.run("loadconfig")

    target =
      case Application.get_env(:cloud, :typst_path) do
        nil -> Path.join(Path.dirname(Mix.Project.project_file()), "priv/bin/typst")
        path -> Path.expand(path)
      end

    case Cloud.Typst.installed_status(target) do
      :pinned ->
        Mix.shell().info("#{target} is already typst #{Cloud.Typst.version()}")
        print_version(target)

      :missing ->
        install(target, opts)

      {:other, sha} ->
        if opts[:force] do
          install(target, opts)
        else
          Mix.raise(
            "#{target} exists but is not the pinned typst binary (sha256 #{sha}), " <>
              "pass --force to replace it"
          )
        end
    end
  end

  defp install(target, opts) do
    {:ok, _} = Application.ensure_all_started(:req)
    work = Path.join(System.tmp_dir!(), "breakline-typst-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)

    try do
      archive = Path.join(work, Cloud.Typst.asset())

      case opts[:archive] do
        nil -> download(archive)
        path -> File.cp!(path, archive)
      end

      sha = file_sha256(archive)

      if sha != Cloud.Typst.archive_sha256() do
        Mix.raise(
          "checksum mismatch for #{Cloud.Typst.asset()}: got #{sha}, " <>
            "expected #{Cloud.Typst.archive_sha256()}"
        )
      end

      member = Cloud.Typst.archive_member()

      case System.cmd("tar", ["-xJf", archive, "-C", work, member], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, status} -> Mix.raise("tar failed (#{status}): #{out}")
      end

      binary = Path.join(work, member)
      File.mkdir_p!(Path.dirname(target))
      # copy next to the target first, then rename, so a half-written binary is never run
      tmp = target <> ".tmp"
      File.cp!(binary, tmp)
      File.chmod!(tmp, 0o755)
      File.rename!(tmp, target)

      Mix.shell().info("installed typst #{Cloud.Typst.version()} to #{target}")
      Mix.shell().info("binary sha256 #{file_sha256(target)}")
      print_version(target)
    after
      File.rm_rf!(work)
    end
  end

  defp download(archive) do
    url = Cloud.Typst.url()
    Mix.shell().info("downloading #{url}")

    case Req.get(url, into: File.stream!(archive), receive_timeout: 600_000, retry: :transient) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> Mix.raise("download failed: http #{status}")
      {:error, error} -> Mix.raise("download failed: #{Exception.message(error)}")
    end
  end

  defp print_version(target) do
    {out, _} = System.cmd(target, ["--version"], stderr_to_stdout: true)
    Mix.shell().info(String.trim(out))
  end

  defp file_sha256(path), do: Cloud.Typst.file_sha256(path)
end
