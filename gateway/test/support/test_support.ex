defmodule Gateway.TestSupport do
  @moduledoc false
  # helpers shared by the enforcer, store and integration tests

  import ExUnit.Assertions

  alias Breakline.{Command, Policy}

  @site "test-site"

  def site, do: @site

  def keypair, do: Command.generate_keypair()

  def b64(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "a policy map for `version`, with test defaults that attrs override"
  def policy_map(version, attrs \\ []) do
    attrs =
      Keyword.merge(
        [
          site_id: @site,
          version: version,
          mode: :enforce,
          time_zone: "Australia/Sydney",
          tool_ids: ["anydesk", "n_central"]
        ],
        attrs
      )

    {:ok, policy} = Policy.new(attrs)
    Policy.to_map(policy)
  end

  @doc """
  a signed policy command. opts: :key_id, :site_id (envelope), :type, :issued_at,
  :ttl_seconds, :payload (replaces the policy map), :policy_version (envelope)
  """
  def signed(priv, version, policy_attrs \\ [], opts \\ []) do
    payload = Keyword.get_lazy(opts, :payload, fn -> policy_map(version, policy_attrs) end)

    command =
      Command.new!(
        type: Keyword.get(opts, :type, "policy"),
        site_id: Keyword.get(opts, :site_id, @site),
        policy_version: Keyword.get(opts, :policy_version, version),
        issued_at: Keyword.get_lazy(opts, :issued_at, fn -> Gateway.Clock.Fake.now() end),
        ttl_seconds: Keyword.get(opts, :ttl_seconds, 3600),
        payload: payload
      )

    Command.sign(command, Keyword.get(opts, :key_id, "k1"), priv)
  end

  def json(wire), do: Command.encode_wire(wire)

  @doc "a fresh empty directory under the test tmp dir"
  def tmp_dir(name) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "breakline-gateway-test",
        "#{name}-#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "polls `fun` until it returns a truthy value, or fails after `timeout_ms`"
  def eventually(fun, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(10)
          do_eventually(fun, deadline)
        end
    end
  end

  @doc "the desired state the fake firewall last applied, or nil"
  def fake_desired do
    case Gateway.Firewall.snapshot() do
      %{state: %{desired: desired}} -> desired
      _ -> nil
    end
  end

  @doc "audit entries of the running store's file, after verifying the chain"
  def audit_entries(data_dir) do
    {:ok, records} = Gateway.Store.read_audit(Path.join(data_dir, "audit.jsonl"))
    Enum.map(records, & &1["entry"])
  end

  def audit_types(data_dir), do: data_dir |> audit_entries() |> Enum.map(& &1["type"])
end
