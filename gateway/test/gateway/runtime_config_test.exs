defmodule Gateway.RuntimeConfigTest do
  # evaluates config/runtime.exs as prod would, with the environment it reads set here
  use ExUnit.Case, async: false

  import Gateway.TestSupport, only: [tmp_dir: 1]

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @vars ~w(BREAKLINE_SITE_ID BREAKLINE_PUBLIC_KEYS BREAKLINE_LAN_INTERFACES BREAKLINE_UPSTREAMS
           BREAKLINE_DATA_DIR BREAKLINE_DEFAULT_MODE BREAKLINE_DNS_IP BREAKLINE_UPLINK_URL
           BREAKLINE_UPLINK_CERT BREAKLINE_UPLINK_KEY BREAKLINE_UPLINK_CA
           BREAKLINE_UPLINK_SERVER_NAME)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{dir: tmp_dir("runtime")}
  end

  defp read(env) do
    System.put_env(env)
    @runtime |> Config.Reader.read!(env: :prod, target: :host) |> Keyword.fetch!(:gateway)
  end

  test "an unenrolled box with no environment boots: no site, no key, no uplink", ctx do
    gw = read(%{"BREAKLINE_DATA_DIR" => ctx.dir})
    assert gw[:site_id] == "unenrolled"
    assert gw[:public_keys] == %{}
    assert gw[:unenrolled?] == true
    assert gw[:data_dir] == ctx.dir
    refute Keyword.has_key?(gw, :uplink)
    refute Keyword.has_key?(gw, :lan_interfaces)
  end

  test "the data directory defaults to /var/lib/breakline" do
    assert read(%{})[:data_dir] == "/var/lib/breakline"
  end

  test "an enrolled box takes its site, keys and uplink from the enrolment", ctx do
    File.write!(
      Path.join(ctx.dir, "enrollment.json"),
      JSON.encode!(%{
        "site_id" => "site-1",
        "public_keys" => %{"cloud-1" => "abc"},
        "uplink_url" => "wss://gw.example.com:4011/gateway/socket/websocket",
        "server_name" => "gw.example.com"
      })
    )

    gw = read(%{"BREAKLINE_DATA_DIR" => ctx.dir, "BREAKLINE_LAN_INTERFACES" => "eth1,eth2"})
    assert gw[:site_id] == "site-1"
    assert gw[:public_keys] == %{"cloud-1" => "abc"}
    assert gw[:unenrolled?] == false
    assert gw[:lan_interfaces] == ["eth1", "eth2"]

    assert gw[:uplink] == [
             url: "wss://gw.example.com:4011/gateway/socket/websocket",
             certfile: Path.join(ctx.dir, "identity/gateway_cert.pem"),
             keyfile: Path.join(ctx.dir, "identity/gateway_key.pem"),
             cacertfile: Path.join(ctx.dir, "server_ca.pem"),
             server_name: "gw.example.com"
           ]

    # a variable that is set still wins
    gw = read(%{"BREAKLINE_DATA_DIR" => ctx.dir, "BREAKLINE_UPLINK_CA" => "/etc/ca.pem"})
    assert gw[:uplink][:cacertfile] == "/etc/ca.pem"
  end

  test "env-only config works as before and still requires its variables", ctx do
    env = %{
      "BREAKLINE_SITE_ID" => "site-9",
      "BREAKLINE_PUBLIC_KEYS" => "k1=aaa,k2=bbb",
      "BREAKLINE_LAN_INTERFACES" => "eth1",
      "BREAKLINE_DATA_DIR" => ctx.dir,
      "BREAKLINE_UPLINK_URL" => "wss://c.example/gateway/socket/websocket",
      "BREAKLINE_UPLINK_CERT" => "/c.pem",
      "BREAKLINE_UPLINK_KEY" => "/k.pem",
      "BREAKLINE_UPLINK_CA" => "/ca.pem"
    }

    # an enrolment on disk does not change an env-configured box
    File.write!(Path.join(ctx.dir, "enrollment.json"), ~s({"site_id": "other"}))

    gw = read(env)
    assert gw[:site_id] == "site-9"
    assert gw[:public_keys] == %{"k1" => "aaa", "k2" => "bbb"}
    assert gw[:lan_interfaces] == ["eth1"]
    assert gw[:unenrolled?] == false

    assert gw[:uplink] == [
             url: "wss://c.example/gateway/socket/websocket",
             certfile: "/c.pem",
             keyfile: "/k.pem",
             cacertfile: "/ca.pem"
           ]

    System.delete_env("BREAKLINE_PUBLIC_KEYS")
    assert_raise RuntimeError, ~r/BREAKLINE_PUBLIC_KEYS is missing/, fn -> read(%{}) end
  end
end
