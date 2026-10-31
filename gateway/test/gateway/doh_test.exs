defmodule Gateway.DoHTest do
  use ExUnit.Case, async: true

  doctest Gateway.DoH

  test "every provider has hostnames and https sources" do
    for p <- Gateway.DoH.providers() do
      assert p["hostnames"] != [], p["id"]
      assert p["sources"] != [], p["id"]
      assert Enum.all?(p["sources"], &String.starts_with?(&1, "https://")), p["id"]
    end
  end

  test "covers the providers the gateway is expected to block" do
    ids = Enum.map(Gateway.DoH.providers(), & &1["id"])
    assert Enum.sort(ids) == ~w(adguard cloudflare google nextdns opendns quad9)
  end

  test "ips are valid and unique" do
    ips = Gateway.DoH.ips()
    assert ips == Enum.uniq(ips)

    for ip <- ips do
      assert {:ok, _} = :inet.parse_strict_address(String.to_charlist(ip)), ip
    end

    for ip <- ~w(1.1.1.1 8.8.8.8 9.9.9.9 149.112.112.112 208.67.222.222 2606:4700:4700::1111) do
      assert ip in ips
    end
  end

  test "hostnames are lowercase and unique" do
    names = Gateway.DoH.hostnames()
    assert names == Enum.uniq(names)
    assert Enum.all?(names, &(&1 == String.downcase(&1)))
  end

  test "canaries" do
    assert Gateway.DoH.canaries() ==
             ~w(use-application-dns.net mask.icloud.com mask-h2.icloud.com)
  end

  test "wildcard entries match below the suffix only" do
    assert Gateway.DoH.match("abc123.dns.nextdns.io") == {:doh, "abc123.dns.nextdns.io"}
    assert Gateway.DoH.match("dns.nextdns.io") == {:doh, "dns.nextdns.io"}
    assert Gateway.DoH.match("nextdns.io") == :nomatch
    assert Gateway.DoH.match("xdns.nextdns.io") == :nomatch
  end

  test "exact entries do not match subdomains or neighbours" do
    assert Gateway.DoH.match("www.dns.google") == :nomatch
    assert Gateway.DoH.match("google") == :nomatch
    assert Gateway.DoH.match("sub.mask.icloud.com") == :nomatch
  end
end
