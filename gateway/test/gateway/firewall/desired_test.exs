defmodule Gateway.Firewall.DesiredTest do
  use ExUnit.Case, async: true

  alias Gateway.Firewall.Desired

  doctest Desired

  defp base(extra \\ []) do
    Keyword.merge(
      [locked?: true, mode: :enforce, lan_interfaces: ["eth1"], dns_port: 5353],
      extra
    )
  end

  test "defaults the optional lists to empty" do
    assert {:ok, d} = Desired.new(base())
    assert d.block_cidrs == [] and d.exclusive_ports == [] and d.doh_ips == []
    assert d.block4 == [] and d.block6 == [] and d.doh4 == [] and d.doh6 == []
  end

  test "locks_at is utc in whole seconds when open, and always nil when locked" do
    sydney =
      DateTime.shift_zone!(
        ~U[2026-11-02 07:00:00.123456Z],
        "Australia/Sydney",
        Tz.TimeZoneDatabase
      )

    assert {:ok, %{locks_at: ~U[2026-11-02 07:00:00Z]}} =
             Desired.new(base(locked?: false, locks_at: sydney))

    assert {:ok, %{locks_at: nil}} = Desired.new(base(locked?: true, locks_at: sydney))
    assert {:ok, %{locks_at: nil}} = Desired.new(base(locked?: false))

    assert {:error, [{:locks_at, "soon", :not_a_datetime}]} =
             Desired.new(base(locked?: false, locks_at: "soon"))
  end

  test "accepts a map as well as a keyword list" do
    assert Desired.new(base()) == Desired.new(Map.new(base()))
  end

  test "splits, normalises, deduplicates and sorts addresses" do
    {:ok, d} =
      Desired.new(
        base(
          block_cidrs: [
            "198.51.100.9",
            "192.0.2.77/24",
            "2001:DB8:0:0::1/128",
            "10.0.0.0/8",
            "10.1.2.3",
            "10.0.0.0/16",
            "2001:db8::/32",
            "2001:db8:1::5",
            "2001:db9::1",
            "198.51.100.9/32"
          ],
          doh_ips: ["9.9.9.9", "1.1.1.1", "2606:4700:4700::1111", "1.1.1.1"]
        )
      )

    assert d.block4 == ["10.0.0.0/8", "192.0.2.0/24", "198.51.100.9"]
    assert d.block6 == ["2001:db8::/32", "2001:db9::1"]
    assert d.block_cidrs == d.block4 ++ d.block6
    assert d.doh4 == ["1.1.1.1", "9.9.9.9"]
    assert d.doh6 == ["2606:4700:4700::1111"]
    assert d.doh_ips == d.doh4 ++ d.doh6
  end

  test "a /0 covers its whole family only" do
    {:ok, d} = Desired.new(base(block_cidrs: ["0.0.0.0/0", "192.0.2.1", "::1"]))
    assert d.block4 == ["0.0.0.0/0"]
    assert d.block6 == ["::1"]
  end

  test "deduplicates and sorts exclusive ports and interfaces" do
    {:ok, d} =
      Desired.new(
        base(
          lan_interfaces: ["eth2", "eth1", "eth2"],
          exclusive_ports: [
            %{port: 7070, proto: :tcp},
            %{port: 5938, proto: :udp},
            %{port: 5938, proto: :tcp},
            %{port: 7070, proto: :tcp}
          ]
        )
      )

    assert d.lan_interfaces == ["eth1", "eth2"]

    assert d.exclusive_ports == [
             %{port: 5938, proto: :tcp},
             %{port: 5938, proto: :udp},
             %{port: 7070, proto: :tcp}
           ]
  end

  test "takes the catalog's exclusive ports as they are" do
    ports = Breakline.Catalog.exclusive_ports(Breakline.Catalog.ids())
    assert {:ok, %Desired{exclusive_ports: ^ports}} = Desired.new(base(exclusive_ports: ports))
  end

  test "reports every problem at once" do
    assert {:error, reasons} =
             Desired.new(%{
               locked?: "yes",
               mode: :block,
               lan_interfaces: ["eth1", "way-too-long-iface-name", "a b", ""],
               dns_port: 0,
               block_cidrs: ["192.0.2.0/33", "nope", "::/129", "10.0.0.1/x", 7],
               exclusive_ports: [%{port: 70_000, proto: :tcp}, %{port: 1, proto: :sctp}, 5],
               doh_ips: ["1.1.1.1/32", "1.1.1"],
               extra: 1
             })

    assert {:extra, 1, :unknown_field} in reasons
    assert {:locked?, "yes", :not_boolean} in reasons
    assert {:mode, :block, :invalid_mode} in reasons
    assert {:dns_port, 0, :invalid_port} in reasons
    assert {:lan_interfaces, "way-too-long-iface-name", :invalid_interface} in reasons
    assert {:lan_interfaces, "a b", :invalid_interface} in reasons
    assert {:lan_interfaces, "", :invalid_interface} in reasons
    assert {:block_cidrs, "192.0.2.0/33", :invalid_prefix} in reasons
    assert {:block_cidrs, "nope", :invalid_address} in reasons
    assert {:block_cidrs, "::/129", :invalid_prefix} in reasons
    assert {:block_cidrs, "10.0.0.1/x", :invalid_prefix} in reasons
    assert {:block_cidrs, 7, :invalid_address} in reasons
    assert {:exclusive_ports, %{port: 70_000, proto: :tcp}, :invalid_port} in reasons
    assert {:exclusive_ports, %{port: 1, proto: :sctp}, :invalid_port_spec} in reasons
    assert {:exclusive_ports, 5, :invalid_port_spec} in reasons
    assert {:doh_ips, "1.1.1.1/32", :cidr_not_allowed} in reasons
    assert {:doh_ips, "1.1.1", :invalid_address} in reasons
    assert length(reasons) == 17
  end

  test "requires the core fields and at least one lan interface" do
    assert {:error, reasons} = Desired.new(%{})

    assert Enum.sort(for {k, nil, :required} <- reasons, do: k) ==
             Enum.sort([:locked?, :mode, :lan_interfaces, :dns_port])

    assert {:error, [{:lan_interfaces, [], :empty_or_not_list}]} =
             Desired.new(base(lan_interfaces: []))

    assert {:error, [{:block_cidrs, "x", :not_a_list}]} = Desired.new(base(block_cidrs: "x"))
    assert {:error, [{:attrs, 1, :not_a_map}]} = Desired.new(1)
  end
end
