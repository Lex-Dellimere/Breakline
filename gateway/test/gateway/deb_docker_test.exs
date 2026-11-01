defmodule Gateway.DebDockerTest do
  # builds the .deb and installs it with apt in a throwaway debian:trixie-slim
  # container, then starts the release as the breakline user with only the unit's two
  # capabilities, the way the unit would. systemd is not pid 1 in the container, so
  # the unit itself only gets `systemd-analyze verify` and `security --offline`.
  # never touches the host's networking: no --network host, no --privileged.
  # excluded by default; run with `mix test --only deb_docker` (needs docker,
  # dpkg-deb and network access for apt-get inside the container).
  use ExUnit.Case, async: false

  @moduletag :deb_docker
  @moduletag timeout: 1_200_000

  @root Path.expand("../..", __DIR__)
  @check Path.expand("../fixtures/deb", __DIR__)
  @image "debian:trixie-slim"

  setup_all do
    for exe <- ~w(docker dpkg-deb) do
      unless System.find_executable(exe), do: raise("#{exe} is required for deb_docker tests")
    end

    out = Gateway.TestSupport.tmp_dir("deb_docker")

    {log, status} =
      System.cmd("mix", ["gateway.package.deb", "--out", out],
        cd: @root,
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix gateway.package.deb failed:\n#{log}"
    [deb] = Path.wildcard(Path.join(out, "breakline-gateway_*.deb"))

    {pub, _priv} = Breakline.Command.generate_keypair()
    keys = "deb-test=" <> Gateway.TestSupport.b64(pub)

    # nft in the container's own network namespace, and the ambient capability
    # the gateway gets. the default set covers apt, setpriv (setuid, setgid,
    # setpcap for the bounding set) and :53 (net_bind_service)
    args =
      ["run", "--rm"] ++
        ["--cap-add", "NET_ADMIN"] ++
        ["-e", "BREAKLINE_SITE_ID=deb-site", "-e", "BREAKLINE_PUBLIC_KEYS=" <> keys] ++
        ["-v", "#{out}:/deb:ro", "-v", "#{@check}:/check:ro"] ++
        [@image, "bash", "/check/check.sh"]

    {stdout, status} = System.cmd("docker", args, stderr_to_stdout: true)
    assert status == 0, "check.sh failed (exit #{status}):\n#{stdout}"

    build_cookie = File.read!(Path.join(@root, "_build/prod/rel/gateway/releases/COOKIE"))
    %{s: sections(stdout), build_cookie: build_cookie}
  end

  # splits stdout on "=== name" marker lines into %{name => body}
  defp sections(stdout) do
    stdout
    |> String.split(~r/^=== /m, trim: true)
    |> Enum.filter(&String.contains?(&1, "\n"))
    |> Map.new(fn chunk ->
      [name, body] = String.split(chunk, "\n", parts: 2)
      {name, String.trim_trailing(body)}
    end)
  end

  test "the breakline system user", %{s: s} do
    [_, _, uid, _gid, _gecos, home, shell] = String.split(s["user"], ":")
    assert String.to_integer(uid) < 1000
    assert home == "/var/lib/breakline"
    assert shell == "/usr/sbin/nologin"
  end

  test "files, owners and modes", %{s: s} do
    modes =
      s["modes"] |> String.split("\n") |> Map.new(&List.to_tuple(String.split(&1, " ", parts: 2)))

    assert modes["/etc/breakline-gateway"] == "root:breakline 750"
    assert modes["/etc/breakline-gateway/cookie"] == "breakline:breakline 400"
    assert modes["/var/lib/breakline"] == "breakline:breakline 700"
    assert modes["/etc/default/breakline-gateway"] == "root:root 644"
    assert modes["/usr/bin/breakline-gateway"] == "root:root 755"
    assert modes["/usr/lib/systemd/system/breakline-gateway.service"] == "root:root 644"
    assert modes["/opt/breakline-gateway/bin/gateway"] == "root:root 755"

    # everything under /opt is root's and writable by nobody else
    assert s["opt_writable_or_not_root"] == ""
    assert s["conffiles"] =~ "/etc/default/breakline-gateway"
    assert s["enabled"] =~ "breakline-gateway.service"
  end

  test "a per-box cookie replaces the build one and survives a reinstall", ctx do
    s = ctx.s
    assert s["cookie_length"] == "48"
    assert s["cookie_charset"] == "0"
    assert s["build_cookie"] =~ "No such file"

    refute s["cookie_sha"] ==
             :crypto.hash(:sha256, ctx.build_cookie) |> Base.encode16(case: :lower)

    assert s["cookie_sha_after_reinstall"] == s["cookie_sha"]
  end

  test "the unit verifies and scores well on systemd-analyze security", %{s: s} do
    assert s["verify"] == "verify ok"

    [_, score] =
      Regex.run(~r/Overall exposure level for breakline-gateway.service: ([\d.]+)/, s["security"])

    assert String.to_float(score) <= 2.0, s["security"]
  end

  test "the release runs as breakline with only net_admin and net_bind_service", %{s: s} do
    assert s["ready"] == "yes"
    assert s["caps"] =~ ~r/^Uid:\s+(\d+)\s+\1\s+\1\s+\1$/m
    refute s["caps"] =~ ~r/^Uid:\s+0\s/m
    # bit 10 (net_bind_service) and bit 12 (net_admin)
    assert s["caps"] =~ ~r/^CapEff:\s+0000000000001400$/m
    assert s["caps"] =~ ~r/^CapAmb:\s+0000000000001400$/m
    assert s["caps"] =~ ~r/^NoNewPrivs:\s+1$/m
  end

  test "it binds :53, applies its nft table and answers dig", %{s: s} do
    # the default bind is :: (dual-stack), which ss lists as *:53
    assert s["listening"] =~ "udp *:53"
    assert s["listening"] =~ "tcp *:53"

    %{"nftables" => objects} = JSON.decode!(s["nft"])

    assert Enum.any?(
             objects,
             &match?(%{"table" => %{"family" => "inet", "name" => "breakline"}}, &1)
           )

    assert Enum.any?(objects, &match?(%{"chain" => %{"name" => "forward"}}, &1))

    # a canary is answered by the gateway itself; a normal name goes upstream
    assert s["dig_canary"] == "status: NXDOMAIN"
    assert s["dig_forwarded"] == "status: NOERROR"
  end

  test "distribution listens on loopback only and there is no epmd", %{s: s} do
    listening = String.split(s["listening"], "\n")
    assert "tcp 127.0.0.1:4370" in listening
    refute Enum.any?(listening, &String.ends_with?(&1, ":4369"))
    refute Enum.any?(listening, &(&1 =~ ~r/:4370$/ and not String.contains?(&1, "127.0.0.1")))

    assert s["dist_remote"] =~ ~r/^\S+:4369 closed$/m
    assert s["dist_remote"] =~ ~r/^(?!127\.)\S+:4370 closed$/m
    assert s["dist_remote"] =~ "127.0.0.1:4370 open"
  end

  test "breakline-gateway status shows the enforcer and uplink", %{s: s} do
    assert s["status"] =~ ~r/state:\s+locked \(no_policy\)/
    assert s["status"] =~ ~r/mode:\s+monitor/
    assert s["status"] =~ ~r/clock synced:\s+yes/
    assert s["status"] =~ ~r/firewall:\s+NftImpl, in sync/
    assert s["status"] =~ ~r/status:\s+not configured/
  end
end
