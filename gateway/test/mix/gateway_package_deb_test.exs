defmodule Mix.Tasks.Gateway.Package.DebTest do
  # the package layout from a fake release, and the wrapper's argument handling
  # against a fake release binary. the real package is tested in deb_docker_test.exs.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Gateway.Package.Deb

  @wrapper Path.expand("../../packaging/deb/breakline-gateway", __DIR__)
  @hex "AB" <> String.duplicate("0123456789abcdef", 3) <> "0123456789abcd"

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o7777)

  describe "stage/3" do
    setup do
      dir = Gateway.TestSupport.tmp_dir("deb_stage")
      release = Path.join(dir, "rel")
      File.mkdir_p!(Path.join(release, "bin"))
      File.mkdir_p!(Path.join(release, "releases/0.1.0"))
      File.mkdir_p!(Path.join(release, "tmp"))
      File.write!(Path.join(release, "bin/gateway"), "#!/bin/sh\n")
      File.chmod!(Path.join(release, "bin/gateway"), 0o775)
      File.write!(Path.join(release, "releases/COOKIE"), "BUILDCOOKIE")
      File.write!(Path.join(release, "releases/0.1.0/sys.config"), "[].")
      File.chmod!(Path.join(release, "releases/0.1.0/sys.config"), 0o666)
      staging = Path.join(dir, "staging")
      :ok = Deb.stage(release, staging, version: "0.1.0", arch: "amd64")
      %{staging: staging}
    end

    test "the release goes under /opt without the build cookie or tmp", %{staging: s} do
      opt = Path.join(s, "opt/breakline-gateway")
      assert mode(Path.join(opt, "bin/gateway")) == 0o755
      assert mode(Path.join(opt, "releases/0.1.0/sys.config")) == 0o644
      refute File.exists?(Path.join(opt, "releases/COOKIE"))
      refute File.exists?(Path.join(opt, "tmp"))
    end

    test "the unit, wrapper, env file, sysusers and docs are in place", %{staging: s} do
      assert mode(Path.join(s, "usr/bin/breakline-gateway")) == 0o755
      assert mode(Path.join(s, "etc/default/breakline-gateway")) == 0o644

      unit = File.read!(Path.join(s, "usr/lib/systemd/system/breakline-gateway.service"))
      assert unit =~ "User=breakline"
      assert unit =~ "StateDirectory=breakline"
      assert unit =~ "CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE"

      assert File.read!(Path.join(s, "usr/lib/sysusers.d/breakline-gateway.conf")) =~
               ~r/^u breakline /m

      examples = Path.join(s, "usr/share/doc/breakline-gateway/examples")

      for f <- ~w(dns-only/interfaces bridge/interfaces bridge/sysctl.conf
                  bridge/modules-load.conf router/interfaces router/sysctl.conf) do
        assert File.regular?(Path.join(examples, f)), f
      end
    end

    test "every runtime.exs variable is documented in the env file", %{staging: s} do
      env = File.read!(Path.join(s, "etc/default/breakline-gateway"))
      runtime = File.read!(Path.expand("../../config/runtime.exs", __DIR__))

      for [var] <- Regex.scan(~r/BREAKLINE_[A-Z_]+/, runtime) |> Enum.uniq() do
        assert env =~ var, "#{var} missing from the env file"
      end
    end

    test "control, conffiles and maintainer scripts", %{staging: s} do
      control = File.read!(Path.join(s, "DEBIAN/control"))
      assert control =~ ~r/^Package: breakline-gateway$/m
      assert control =~ ~r/^Version: 0.1.0$/m
      assert control =~ ~r/^Architecture: amd64$/m
      assert control =~ ~r/^Installed-Size: \d+$/m
      assert control =~ ~r/^Depends: .*\bnftables\b/m
      assert control =~ ~r/^Depends: .*systemd-timesyncd \| time-daemon/m

      assert File.read!(Path.join(s, "DEBIAN/conffiles")) == "/etc/default/breakline-gateway\n"

      for script <- ~w(postinst prerm postrm) do
        assert mode(Path.join(s, "DEBIAN/#{script}")) == 0o755
      end
    end
  end

  describe "the breakline-gateway wrapper" do
    setup do
      dir = Gateway.TestSupport.tmp_dir("deb_wrapper")
      log = Path.join(dir, "calls.log")

      # stands in for bin/gateway and systemctl: logs its args and the enrol env
      fake = Path.join(dir, "fake")

      File.write!(fake, """
      #!/bin/sh
      {
        echo "$(basename "$0") $*"
        env | grep -E '^BREAKLINE_(ENROLL_|DATA_DIR|SITE_ID)' | sort
      } >>"#{log}"
      exit "${FAKE_EXIT:-0}"
      """)

      File.chmod!(fake, 0o755)
      File.ln_s!(fake, Path.join(dir, "gateway"))
      File.ln_s!(fake, Path.join(dir, "systemctl"))

      env_file = Path.join(dir, "default")
      File.write!(env_file, "# comment\nBREAKLINE_SITE_ID=site-1\n")

      env = [
        {"BREAKLINE_GATEWAY_BIN", Path.join(dir, "gateway")},
        {"BREAKLINE_SYSTEMCTL_BIN", Path.join(dir, "systemctl")},
        {"BREAKLINE_ENV_FILE", env_file},
        {"BREAKLINE_USER", "id" |> System.cmd(["-un"]) |> elem(0) |> String.trim()}
      ]

      %{env: env, log: log}
    end

    defp wrapper(ctx, args, extra_env \\ []) do
      System.cmd("sh", [@wrapper | args], env: ctx.env ++ extra_env, stderr_to_stdout: true)
    end

    defp calls(ctx), do: if(File.exists?(ctx.log), do: File.read!(ctx.log), else: "")

    test "enroll runs the enrol function with the contract's env, then restarts", ctx do
      {out, 0} =
        wrapper(ctx, ["enroll", "https://cloud.example", "ABCD-1234", "--ca-sha256", @hex])

      assert out =~ "enrolled"

      assert calls(ctx) == """
             gateway eval Gateway.Enroll.run_from_env()
             BREAKLINE_DATA_DIR=/var/lib/breakline
             BREAKLINE_ENROLL_CA_SHA256=#{String.downcase(@hex)}
             BREAKLINE_ENROLL_CODE=ABCD-1234
             BREAKLINE_ENROLL_URL=https://cloud.example
             BREAKLINE_SITE_ID=site-1
             systemctl restart breakline-gateway
             BREAKLINE_DATA_DIR=/var/lib/breakline
             BREAKLINE_ENROLL_CA_SHA256=#{String.downcase(@hex)}
             BREAKLINE_ENROLL_CODE=ABCD-1234
             BREAKLINE_ENROLL_URL=https://cloud.example
             BREAKLINE_SITE_ID=site-1
             """
    end

    test "a failed enrolment exits non-zero and leaves the service alone", ctx do
      {out, status} =
        wrapper(ctx, ["enroll", "https://c.example", "X", "--ca-sha256", @hex], [
          {"FAKE_EXIT", "3"}
        ])

      assert status != 0
      assert out =~ "enrolment failed"
      assert calls(ctx) =~ "gateway eval"
      refute calls(ctx) =~ "systemctl"
    end

    test "bad enroll arguments never reach the release", ctx do
      bad = [
        ["enroll"],
        ["enroll", "https://c.example", "X"],
        ["enroll", "https://c.example", "X", "--ca-sha256"],
        ["enroll", "https://c.example", "X", "--ca", @hex],
        ["enroll", "https://c.example", "--ca-sha256", @hex, "X"],
        ["enroll", "https://c.example", "X", "--ca-sha256", @hex, "extra"],
        ["enroll", "http://c.example", "X", "--ca-sha256", @hex],
        ["enroll", "https://", "X", "--ca-sha256", @hex],
        ["enroll", "https://c.example", "", "--ca-sha256", @hex],
        ["enroll", "https://c.example", "a b", "--ca-sha256", @hex],
        ["enroll", "https://c.example", "X", "--ca-sha256", "abc123"],
        ["enroll", "https://c.example", "X", "--ca-sha256", String.duplicate("g", 64)],
        ["enroll", "https://c.example", "X", "--ca-sha256", @hex <> "0"]
      ]

      for args <- bad do
        {_out, status} = wrapper(ctx, args)
        assert status != 0, inspect(args)
      end

      assert calls(ctx) == ""
    end

    test "status asks the running node over rpc", ctx do
      {_, 0} = wrapper(ctx, ["status"])
      assert calls(ctx) =~ "gateway rpc Gateway.Status.print()"

      {out, status} = wrapper(ctx, ["status"], [{"FAKE_EXIT", "1"}])
      assert status != 0
      assert out =~ "could not reach the gateway"
    end

    test "no command, an unknown one or extra status args print usage", ctx do
      for args <- [[], ["start"], ["status", "now"]] do
        {out, status} = wrapper(ctx, args)
        assert status == 2, inspect(args)
        assert out =~ "usage: breakline-gateway status"
      end

      assert calls(ctx) == ""
    end
  end
end
