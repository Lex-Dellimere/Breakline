defmodule Mix.Tasks.Gateway.Package.Deb do
  @shortdoc "Builds the breakline-gateway .deb for the pilot box"

  @moduledoc """
  Builds the prod release and packages it as `breakline-gateway_<vsn>_<arch>.deb`
  with `dpkg-deb`, for Debian 13 (trixie).

      mix gateway.package.deb [--out DIR] [--no-release]

  Runs in `MIX_ENV=prod` (the preferred env). `--out` is where the .deb goes
  (default `_build/prod`). `--no-release` packages the release already in
  `_build/prod/rel/gateway` instead of building it again.

  The release bundles the build host's erts, which links against that host's
  libraries, so build on Debian 13 amd64 for the pilot box.

  The package installs:

    * the release under `/opt/breakline-gateway`, without the build-time erlang
      cookie: `postinst` writes a per-box one to `/etc/breakline-gateway/cookie`,
      readable only by the `breakline` user, and `rel/env.sh.eex` reads it
    * `/usr/lib/systemd/system/breakline-gateway.service`, the hardened unit
    * `/etc/default/breakline-gateway`, a conffile with the env vars `runtime.exs`
      reads
    * `/usr/bin/breakline-gateway` with `status` and `enroll`
    * `/usr/lib/sysusers.d/breakline-gateway.conf`, the `breakline` system user
    * `/usr/share/doc/breakline-gateway/`: `PILOT.md` and network config examples
      for each install mode

  The package sources are in `packaging/deb/`.
  """

  use Mix.Task

  @package "breakline-gateway"
  @source Path.expand("../../../packaging/deb", __DIR__)
  @pilot_doc Path.expand("../../../../docs/PILOT.md", __DIR__)

  # the release's erts and nifs link against these (ldd on a trixie build), and the
  # gateway runs nft, timedatectl (d-bus to timedated) and setpriv
  @depends [
    "libc6",
    "libgcc-s1",
    "libstdc++6",
    "libssl3t64",
    "libtinfo6",
    "zlib1g",
    "libsystemd0",
    "nftables",
    "systemd",
    "systemd-timesyncd | time-daemon",
    "default-dbus-system-bus | dbus-system-bus",
    "util-linux",
    "init-system-helpers"
  ]

  @suggests ["bind9-dnsutils", "bridge-utils"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [out: :string, release: :boolean])

    if Mix.env() != :prod do
      Mix.raise("run with MIX_ENV=prod (got #{Mix.env()})")
    end

    release = Path.join(Mix.Project.build_path(), "rel/gateway")

    if Keyword.get(opts, :release, true) do
      # a clean release dir, so nothing left over from an older build gets packaged
      File.rm_rf!(release)
      Mix.Task.run("release", ["--overwrite", "--quiet"])
    end

    unless File.dir?(release), do: Mix.raise("no release at #{release}")

    version = Mix.Project.config()[:version]
    arch = architecture()
    out = Path.expand(Keyword.get(opts, :out, Mix.Project.build_path()))
    staging = Path.join(Mix.Project.build_path(), "deb/#{@package}")

    File.rm_rf!(staging)
    stage(release, staging, version: version, arch: arch)

    File.mkdir_p!(out)
    deb = Path.join(out, "#{@package}_#{version}_#{arch}.deb")

    case System.cmd("dpkg-deb", ["--root-owner-group", "-Zxz", "--build", staging, deb],
           stderr_to_stdout: true
         ) do
      {_, 0} -> Mix.shell().info("wrote #{deb}")
      {output, status} -> Mix.raise("dpkg-deb failed (exit #{status}):\n#{output}")
    end
  end

  @doc """
  Lays out the package tree for `release` under `staging`, including `DEBIAN/`.
  Options: `:version` and `:arch` (both required).
  """
  @spec stage(Path.t(), Path.t(), keyword()) :: :ok
  def stage(release, staging, opts) do
    version = Keyword.fetch!(opts, :version)
    arch = Keyword.fetch!(opts, :arch)

    opt = Path.join(staging, "opt/#{@package}")
    File.mkdir_p!(Path.dirname(opt))
    {_, 0} = System.cmd("cp", ["-a", release, opt])

    # never ship the build-time cookie: every box would share it
    File.rm!(Path.join(opt, "releases/COOKIE"))
    File.rm_rf!(Path.join(opt, "tmp"))
    {_, 0} = System.cmd("chmod", ["-R", "u+rwX,go+rX,go-w", opt])

    install("breakline-gateway", staging, "usr/bin/#{@package}", 0o755)
    install("breakline-gateway.service", staging, "usr/lib/systemd/system/#{@package}.service")
    install("default", staging, "etc/default/#{@package}")
    install("sysusers.conf", staging, "usr/lib/sysusers.d/#{@package}.conf")

    doc = "usr/share/doc/#{@package}"

    for path <- Path.wildcard(Path.join(@source, "examples/**/*")), File.regular?(path) do
      install(
        Path.relative_to(path, @source),
        staging,
        Path.join(doc, Path.relative_to(path, @source))
      )
    end

    if File.exists?(@pilot_doc) do
      File.cp!(@pilot_doc, Path.join([staging, doc, "PILOT.md"]))
      File.chmod!(Path.join([staging, doc, "PILOT.md"]), 0o644)
    end

    debian = Path.join(staging, "DEBIAN")

    for script <- ~w(postinst prerm postrm) do
      install(script, staging, "DEBIAN/#{script}", 0o755)
    end

    File.write!(Path.join(debian, "conffiles"), "/etc/default/#{@package}\n")
    size = installed_size_kib(staging)
    File.write!(Path.join(debian, "control"), control(version, arch, size))

    for file <- ~w(conffiles control), do: File.chmod!(Path.join(debian, file), 0o644)
    {_, 0} = System.cmd("find", [staging, "-type", "d", "-exec", "chmod", "0755", "{}", "+"])
    :ok
  end

  @doc "The `DEBIAN/control` text."
  @spec control(String.t(), String.t(), non_neg_integer()) :: String.t()
  def control(version, arch, installed_size_kib) do
    """
    Package: #{@package}
    Version: #{version}
    Architecture: #{arch}
    Maintainer: Breakline <ops@breakline.invalid>
    Installed-Size: #{installed_size_kib}
    Depends: #{Enum.join(@depends, ", ")}
    Suggests: #{Enum.join(@suggests, ", ")}
    Section: net
    Priority: optional
    Description: Breakline site gateway
     Keeps a managed service provider's remote-access (RMM) tools closed at the
     site's network edge unless the client's signed policy opens a window, with a
     DNS resolver and an nftables table. Runs as a hardened systemd service.
    """
  end

  defp install(from, staging, to, mode \\ 0o644) do
    dest = Path.join(staging, to)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(Path.join(@source, from), dest)
    File.chmod!(dest, mode)
  end

  defp installed_size_kib(staging) do
    {out, 0} = System.cmd("du", ["-sk", "--exclude=DEBIAN", staging])
    out |> String.split() |> hd() |> String.to_integer()
  end

  defp architecture do
    case System.cmd("dpkg", ["--print-architecture"]) do
      {arch, 0} -> String.trim(arch)
      _ -> Mix.raise("dpkg --print-architecture failed; build on debian")
    end
  end
end
