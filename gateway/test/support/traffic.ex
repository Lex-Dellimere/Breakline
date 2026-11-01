defmodule Gateway.Traffic do
  @moduledoc false
  # helpers for the traffic tests (mix test --only traffic): a throwaway debian
  # container per topology, the prod release mounted read-only in it, and probes run
  # from the client namespace. everything here talks to the container through
  # docker exec; nothing touches the host's networking.

  import ExUnit.Assertions

  alias Breakline.{Command, Policy}

  @gateway_dir Path.expand("../..", __DIR__)
  @fixtures Path.join(@gateway_dir, "test/fixtures/traffic")
  @release Path.join(@gateway_dir, "_build/prod/rel/gateway")
  @image "debian:trixie-slim"
  @site "traffic-site"
  @key_id "traffic"
  @tools ["anydesk", "screenconnect", "teamviewer"]

  @doc """
  builds the prod release once per test run, whichever module asks first, and
  returns its path
  """
  def release! do
    # the first caller builds in the agent's init, which holds the name while it
    # runs; later callers get :already_started and wait in Agent.get
    name = Module.concat(__MODULE__, Release)

    pid =
      case Agent.start(&build_release/0, name: name) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    case Agent.get(pid, & &1, :infinity) do
      {:ok, path} -> path
      {:error, out} -> raise("MIX_ENV=prod mix release failed:\n#{out}")
    end
  end

  defp build_release do
    {out, status} =
      System.cmd("mix", ["release", "--overwrite", "--quiet"],
        cd: @gateway_dir,
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    if status == 0, do: {:ok, @release}, else: {:error, out}
  end

  @doc """
  starts a container, builds `topology` in it and starts the gateway with no
  policy. returns the context map the other helpers take. `bridge_nf: false`
  leaves br_netfilter's sysctls off in the container's namespace.
  """
  def start!(topology, opts \\ []) do
    unless System.find_executable("docker"), do: raise("docker is required for traffic tests")
    release = release!()

    dir = Path.join(System.tmp_dir!(), "breakline-traffic-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    bridge_nf = if Keyword.get(opts, :bridge_nf, true), do: "1", else: "0"

    sysctls =
      [
        "net.ipv4.ip_forward=1",
        "net.ipv6.conf.all.forwarding=1",
        "net.ipv6.conf.all.disable_ipv6=0",
        "net.ipv6.conf.default.disable_ipv6=0"
      ] ++
        if topology == :bridge,
          do: [
            "net.bridge.bridge-nf-call-iptables=#{bridge_nf}",
            "net.bridge.bridge-nf-call-ip6tables=#{bridge_nf}"
          ],
          else: []

    # NET_ADMIN for links, routes and nftables. SYS_ADMIN for unshare and nsenter,
    # which create and enter the client and upstream namespaces. --init reaps the
    # killed beam, so a crash test sees it gone. the sleep bounds the container's life
    # should the test vm die without cleaning up.
    args =
      ["run", "-d", "--rm", "--init", "--cap-add", "NET_ADMIN", "--cap-add", "SYS_ADMIN"] ++
        Enum.flat_map(sysctls, &["--sysctl", &1]) ++
        ["-v", "#{release}:/opt/gateway:ro", "-v", "#{@fixtures}:/traffic:ro"] ++
        ["-v", "#{dir}:/policies:ro", @image, "sleep", "1800"]

    {out, 0} = System.cmd("docker", args, stderr_to_stdout: true)
    cid = String.trim(out)
    ExUnit.Callbacks.on_exit(fn -> stop!(cid, dir) end)

    {out, status} = exec(cid, ["/traffic/setup.sh", Atom.to_string(topology)])
    assert status == 0, "setup failed (exit #{status}):\n#{out}"

    {pub, priv} = Command.generate_keypair()

    env =
      %{
        "BREAKLINE_SITE_ID" => @site,
        "BREAKLINE_PUBLIC_KEYS" => "#{@key_id}=#{Base.url_encode64(pub, padding: false)}",
        "BREAKLINE_DATA_DIR" => "/run/bl/data",
        # the release refuses to start or rpc without a cookie
        "RELEASE_COOKIE" => "traffic-#{System.unique_integer([:positive])}"
      }
      |> Map.merge(topology_env(topology))
      |> Map.merge(Map.new(Keyword.get(opts, :env, [])))

    ctx = %{cid: cid, dir: dir, priv: priv, topology: topology}
    write_env(ctx, env)
    start_gateway!(ctx)
    Map.put(ctx, :env, env)
  end

  defp topology_env(:router),
    do: %{"BREAKLINE_LAN_INTERFACES" => "lan0", "BREAKLINE_UPSTREAMS" => "10.20.0.2"}

  defp topology_env(:bridge),
    do: %{"BREAKLINE_LAN_INTERFACES" => "br0", "BREAKLINE_UPSTREAMS" => "10.30.0.3"}

  @doc "rewrites the release's environment, for the next start"
  def write_env(ctx, env) do
    body = Enum.map_join(Enum.sort(env), "", fn {k, v} -> "#{k}=#{v}\n" end)
    File.write!(Path.join(ctx.dir, "gateway.env"), body)
  end

  defp stop!(cid, dir) do
    System.cmd("docker", ["kill", cid], stderr_to_stdout: true)
    File.rm_rf!(dir)
  end

  @doc "runs a command in the container (the gateway's namespace)"
  def exec(cid, args) when is_binary(cid), do: System.cmd("docker", ["exec", cid | args])
  def exec(%{cid: cid}, args), do: exec(cid, args)

  def exec!(ctx, args) do
    {out, status} = exec(ctx, args)
    assert status == 0, "#{Enum.join(args, " ")} failed (exit #{status}):\n#{out}"
    out
  end

  ## the gateway

  @doc "starts the release and waits until the enforcer answers"
  def start_gateway!(ctx) do
    exec!(ctx, ["/traffic/gateway.sh", "start"])
    await(fn -> match?({:ok, _}, try_status(ctx)) end, 30_000, "the gateway to start")
  end

  @doc "kills the beam with SIGKILL and waits until it is gone"
  def kill_gateway!(ctx), do: exec!(ctx, ["/traffic/gateway.sh", "kill"])

  @doc "evaluates `expr` on the running node and returns the term it evaluates to"
  def rpc(ctx, expr) do
    wrapped = "IO.write(Base.encode64(:erlang.term_to_binary((#{expr}))))"

    case exec(ctx, ["/traffic/gateway.sh", "rpc", wrapped]) do
      {out, 0} ->
        case out |> String.split("\n", trim: true) |> List.last() |> decode() do
          {:ok, term} -> {:ok, term}
          :error -> {:error, out}
        end

      {out, _} ->
        {:error, out}
    end
  end

  defp decode(nil), do: :error

  defp decode(line) do
    case Base.decode64(String.trim(line)) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin)}
      :error -> :error
    end
  end

  def rpc!(ctx, expr) do
    case rpc(ctx, expr) do
      {:ok, term} -> term
      {:error, out} -> flunk("rpc #{expr} failed:\n#{out}")
    end
  end

  defp try_status(ctx), do: rpc(ctx, "Gateway.Enforcer.status()")

  def status(ctx), do: rpc!(ctx, "Gateway.Enforcer.status()")

  @doc "polls the enforcer status until `fun` returns true for it"
  def await_status(ctx, fun, timeout \\ 20_000) do
    await(
      fn ->
        case try_status(ctx) do
          {:ok, status} -> if fun.(status), do: status
          _ -> nil
        end
      end,
      timeout,
      "the enforcer status"
    )
  end

  ## policies

  @doc """
  signs a policy with `attrs` over the traffic test defaults, submits it over rpc
  and returns the enforcer status right after
  """
  def submit!(ctx, attrs) do
    version = System.os_time(:microsecond)

    {:ok, policy} =
      [
        site_id: @site,
        version: version,
        mode: :enforce,
        time_zone: "Australia/Sydney",
        tool_ids: @tools
      ]
      |> Keyword.merge(attrs)
      |> Policy.new()

    json =
      [
        type: "policy",
        site_id: @site,
        policy_version: version,
        ttl_seconds: 600,
        payload: Policy.to_map(policy)
      ]
      |> Command.new!()
      |> Command.sign(@key_id, ctx.priv)
      |> Command.encode_wire()

    name = "policy-#{version}.json"
    File.write!(Path.join(ctx.dir, name), json)

    # one rpc for both, so a short window is still open in the status we return
    expr =
      ~s|{Gateway.Enforcer.submit(File.read!("/policies/#{name}")), Gateway.Enforcer.status()}|

    assert {:ok, %{policy_version: ^version} = status} = rpc!(ctx, expr)
    status
  end

  @doc "a policy with no windows: locked"
  def lock!(ctx, mode \\ :enforce) do
    status = submit!(ctx, mode: mode)
    assert %{state: :locked, mode: ^mode} = status
    status
  end

  @doc "an approver's break-glass, open for `seconds` from now. returns the end"
  def open!(ctx, seconds, mode \\ :enforce) do
    until = DateTime.add(DateTime.utc_now(), seconds) |> DateTime.truncate(:second)
    status = submit!(ctx, mode: mode, break_glass: %{until: until, approved_by: "traffic"})
    assert %{state: :open} = status
    until
  end

  ## dns

  @doc """
  runs dig in a namespace (`:client` by default) and returns `%{status:, answers:}`.
  status is :noerror, :nxdomain, :servfail, :refused (connection refused) or
  :timeout. opts: `:type` ("A"), `:tcp`, `:from`
  """
  def dig(ctx, server, name, opts \\ []) do
    tcp = if opts[:tcp], do: ["+tcp"], else: []
    from = opts |> Keyword.get(:from, :client) |> Atom.to_string()
    args = ["/run/bl/in", from, "dig", "+time=2", "+tries=1"] ++ tcp
    {out, _} = exec(ctx, args ++ ["@" <> server, Keyword.get(opts, :type, "A"), name])

    status =
      case Regex.run(~r/status: ([A-Z]+)/, out) do
        [_, s] ->
          s |> String.downcase() |> String.to_atom()

        nil ->
          cond do
            out =~ "connection refused" -> :refused
            out =~ "timed out" or out =~ "no servers could be reached" -> :timeout
            true -> {:unknown, out}
          end
      end

    answers =
      for [_, _type, value] <- Regex.scan(~r/^\S+\s+\d+\s+IN\s+(A|AAAA)\s+(\S+)$/m, out),
          do: value

    %{status: status, answers: answers}
  end

  ## probes

  @doc """
  probes from the client namespace, in parallel. `specs` are `{:tcp, host, port}`
  (the handshake completes) or `{:udp, host, port}` (upstream logged the datagram).
  returns `%{spec => :pass | :drop}`.
  """
  def probe(ctx, specs) do
    specs
    |> Task.async_stream(fn spec -> {spec, probe_one(ctx, spec)} end,
      timeout: 15_000,
      max_concurrency: 16
    )
    |> Map.new(fn {:ok, r} -> r end)
  end

  @doc "runs the same probe `n` times in parallel, each a new connection or flow"
  def probe_times(ctx, spec, n) do
    1..n
    |> Task.async_stream(fn _ -> probe_one(ctx, spec) end, timeout: 15_000, max_concurrency: 16)
    |> Enum.map(fn {:ok, r} -> r end)
  end

  defp probe_one(ctx, {:tcp, host, port}),
    do: result(exec(ctx, ["/traffic/probe.sh", "tcp", host, "#{port}"]))

  defp probe_one(ctx, {:udp, host, port}) do
    token = "t#{System.unique_integer([:positive])}"
    result(exec(ctx, ["/traffic/probe.sh", "udp", host, "#{port}", token]))
  end

  defp result({out, 0}) do
    case String.trim(out) do
      "pass" -> :pass
      "drop" -> :drop
    end
  end

  @doc "asserts every probe in `expected` (`%{spec => :pass | :drop}`) at once"
  def assert_probes(ctx, expected) do
    actual = probe(ctx, Map.keys(expected))
    wrong = for {spec, want} <- expected, actual[spec] != want, do: {spec, want, actual[spec]}

    assert wrong == [],
           "probes that did not behave (spec, expected, actual):\n" <>
             Enum.map_join(wrong, "\n", &inspect/1)
  end

  ## sessions

  @doc """
  starts a long-lived tcp session from the client that sends a timestamp every
  200 ms and waits until the echo flows. returns the output path.
  """
  def start_session!(ctx, host, port) do
    out = "/run/bl/session-#{System.unique_integer([:positive])}.out"

    {_, 0} =
      System.cmd("docker", [
        "exec",
        "-d",
        ctx.cid,
        "/traffic/probe.sh",
        "session",
        host,
        "#{port}",
        out
      ])

    await(fn -> length(session(ctx, out)) >= 3 end, 10_000, "session #{host}:#{port} to flow")
    out
  end

  @doc "the timestamps echoed back so far"
  def session(ctx, out) do
    {text, _} = exec(ctx, ["cat", out])

    for line <- String.split(text, "\n", trim: true),
        {t, ""} <- [Float.parse(line)],
        do: t
  end

  def stop_session(ctx, out), do: exec(ctx, ["pkill", "-f", out])

  @doc """
  waits until the session's echo has stopped for 2 s and returns the unix time of
  the last echoed timestamp
  """
  def await_cut(ctx, out, timeout \\ 20_000) do
    await(
      fn ->
        case session(ctx, out) do
          [] -> nil
          ts -> if now() - List.last(ts) > 2.0, do: List.last(ts)
        end
      end,
      timeout,
      "session #{out} to be cut"
    )
  end

  def now, do: System.os_time(:millisecond) / 1000

  ## nftables

  @doc "`nft -j list <what>` in the gateway namespace, decoded"
  def nft(ctx, what) do
    {out, status} = exec(ctx, ["nft", "-j", "list" | String.split(what)])
    if status == 0, do: {:ok, JSON.decode!(out)["nftables"]}, else: {:error, out}
  end

  def nft!(ctx, what) do
    {:ok, list} = nft(ctx, what)
    list
  end

  @doc "the addresses in one of the table's sets"
  def set_members(ctx, set) do
    [%{"set" => s}] = for %{"set" => _} = o <- nft!(ctx, "set inet breakline #{set}"), do: o

    for %{"elem" => %{"val" => v}} <- Map.get(s, "elem", []), do: v
  end

  def await_member(ctx, set, ip) do
    await(fn -> ip in set_members(ctx, set) end, 10_000, "#{ip} in #{set}")
  end

  @doc "the forward rules of the table"
  def forward_rules(ctx) do
    for %{"rule" => %{"chain" => "forward"} = r} <- nft!(ctx, "chain inet breakline forward"),
        do: r
  end

  @doc """
  counter packets per monitor rule, keyed `{reason, [protocols matched]}`, for
  example `{"port", ["tcp"]}` or `{"doh", ["ip", "tcp"]}`
  """
  def counters(ctx) do
    Map.new(forward_rules(ctx), fn r ->
      reason =
        Enum.find_value(r["expr"], fn
          %{"log" => %{"prefix" => p}} -> p |> String.split() |> List.last()
          _ -> nil
        end)

      protos =
        for %{"match" => %{"left" => %{"payload" => %{"protocol" => p}}}} <- r["expr"], do: p

      packets = Enum.find_value(r["expr"], fn e -> get_in(e, ["counter", "packets"]) end)
      {{reason, protos}, packets}
    end)
  end

  ## polling

  @doc "calls `fun` every 200 ms until it returns a truthy value, which it returns"
  def await(fun, timeout, what) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline, what)
  end

  defp do_await(fun, deadline, what) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("timed out waiting for #{what}")
        else
          Process.sleep(200)
          do_await(fun, deadline, what)
        end
    end
  end
end
