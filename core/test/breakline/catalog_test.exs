defmodule Breakline.CatalogTest do
  use ExUnit.Case, async: true

  alias Breakline.Catalog
  alias Breakline.Catalog.{DomainPattern, Loader, Tool}

  doctest Catalog
  doctest Loader

  @contract_ids ~w(n_central take_control screenconnect ninjaone datto_rmm anydesk teamviewer splashtop)

  @snapshot "../../priv/catalog/lolrmm_snapshot.json"
            |> Path.expand(__DIR__)
            |> File.read!()
            |> JSON.decode!()

  # slug => set of lowercased domains that lolrmm says to detect on
  defp detectable_domains(slug) do
    tool = Map.fetch!(@snapshot["tools"], slug)

    for network <- get_in(tool, ["Artifacts", "Network"]) || [],
        Map.get(network, "Detection") != false,
        domain <- Map.get(network, "Domains") || [],
        into: MapSet.new(),
        do: domain |> String.trim() |> String.downcase()
  end

  defp all_snapshot_domains(slug) do
    tool = Map.fetch!(@snapshot["tools"], slug)

    for network <- get_in(tool, ["Artifacts", "Network"]) || [],
        domain <- Map.get(network, "Domains") || [],
        into: MapSet.new(),
        do: domain |> String.trim() |> String.downcase()
  end

  defp lolrmm_slug("lolrmm:" <> slug), do: slug
  defp lolrmm_slug(_), do: nil

  # a concrete name the pattern matches, for overlap checks
  defp sample_name(pattern) do
    pattern |> String.replace_prefix("*.", "sample.") |> String.replace("*", "x")
  end

  describe "contract" do
    test "every contract tool id exists and nothing else does" do
      assert Enum.sort(Catalog.ids()) == Enum.sort(@contract_ids)

      for id <- @contract_ids do
        assert {:ok, %Tool{id: ^id}} = Catalog.get(id)
      end
    end

    test "tools/0 and ids/0 agree" do
      assert Enum.map(Catalog.tools(), & &1.id) == Catalog.ids()
    end

    test "every tool has domains or ports, a kev key and sourced entries" do
      for tool <- Catalog.tools() do
        assert tool.domains != [], "#{tool.id} has no domains"
        assert tool.kev_keys != [], "#{tool.id} has no kev keys"

        for entry <- tool.domains ++ tool.ports ++ tool.excluded do
          assert lolrmm_slug(entry.source) || String.starts_with?(entry.source, "https://"),
                 "#{tool.id} entry #{inspect(entry)} has no usable source"
        end
      end
    end
  end

  describe "provenance" do
    test "the snapshot records licence and source" do
      assert @snapshot["license"] == "Apache-2.0"
      assert @snapshot["source"] =~ "lolrmm.io"
      assert {:ok, _, _} = DateTime.from_iso8601(@snapshot["fetched_at"])
    end

    test "every lolrmm-sourced domain is a detectable domain of that slug in the snapshot" do
      for tool <- Catalog.tools(), %{pattern: pattern, source: source} <- tool.domains do
        if slug = lolrmm_slug(source) do
          assert Map.has_key?(@snapshot["tools"], slug), "#{source} not in snapshot"

          assert MapSet.member?(detectable_domains(slug), pattern),
                 "#{tool.id}: #{pattern} not a detectable domain of #{slug}"
        end
      end
    end

    test "every lolrmm-sourced excluded pattern exists in the snapshot" do
      for tool <- Catalog.tools(), %{pattern: pattern, source: source} <- tool.excluded do
        if slug = lolrmm_slug(source) do
          assert MapSet.member?(all_snapshot_domains(slug), String.downcase(pattern)),
                 "#{tool.id}: excluded #{pattern} not in #{slug}"
        end
      end
    end

    test "every lolrmm-sourced port is listed by that slug in the snapshot" do
      for tool <- Catalog.tools(), %{port: port, source: source} <- tool.ports do
        if slug = lolrmm_slug(source) do
          ports =
            for network <- get_in(@snapshot, ["tools", slug, "Artifacts", "Network"]) || [],
                Map.get(network, "Detection") != false,
                p <- Map.get(network, "Ports") || [],
                do: if(is_binary(p), do: String.to_integer(String.trim(p)), else: p)

          assert port in ports, "#{tool.id}: port #{port} not in #{slug}"
        end
      end
    end

    test "the user_managed placeholder never appears" do
      for tool <- Catalog.tools(), d <- tool.domains do
        refute d.pattern =~ "user_managed"
      end
    end
  end

  describe "exclusions" do
    test "no excluded pattern appears in any tool's domains" do
      domains = for tool <- Catalog.tools(), d <- tool.domains, into: MapSet.new(), do: d.pattern

      for tool <- Catalog.tools(), e <- tool.excluded do
        refute MapSet.member?(domains, e.pattern), "#{e.pattern} is both excluded and blocked"
        assert is_binary(e.reason) and e.reason != ""
      end
    end

    test "over-broad parent-company names are not blocked" do
      for name <-
            ~w(connectwise.com home.connectwise.com na.myconnectwise.net university.connectwise.com
                     n-able.com me.n-able.com documentation.n-able.com) do
        assert Catalog.match_domain(name) == :nomatch, "#{name} should not be blocked"
      end
    end

    test "tools do not overlap, so match_domain does not depend on order" do
      for a <- Catalog.tools(), b <- Catalog.tools(), a.id != b.id, d <- a.domains do
        name = sample_name(d.pattern)
        assert DomainPattern.match?(d.compiled, name)

        refute Enum.any?(b.domains, &DomainPattern.match?(&1.compiled, name)),
               "#{a.id} #{d.pattern} also matches #{b.id}"
      end
    end
  end

  describe "match_domain/2" do
    test "matches representative names" do
      assert Catalog.match_domain("router15.teamviewer.com") == {:ok, "teamviewer"}
      assert Catalog.match_domain("relay-5f3a.net.anydesk.com") == {:ok, "anydesk"}

      assert Catalog.match_domain("instance-x1-relay.screenconnect.com.") ==
               {:ok, "screenconnect"}

      assert Catalog.match_domain("comserver.us1.mspa.n-able.com") == {:ok, "take_control"}
      assert Catalog.match_domain("SIS.N-ABLE.COM") == {:ok, "n_central"}
      assert Catalog.match_domain("concord.rmm.datto.com") == {:ok, "datto_rmm"}
      assert Catalog.match_domain("app.ninjarmm.com") == {:ok, "ninjaone"}
      assert Catalog.match_domain("st-relay.relay.splashtop.com") == {:ok, "splashtop"}
    end

    test "respects the tool id filter and ignores unknown ids" do
      assert Catalog.match_domain("router15.teamviewer.com", ["anydesk"]) == :nomatch

      assert Catalog.match_domain("router15.teamviewer.com", ["bogus", "teamviewer"]) ==
               {:ok, "teamviewer"}

      assert Catalog.match_domain("router15.teamviewer.com", []) == :nomatch
    end

    test "does not match bare suffixes of leading wildcards or unrelated names" do
      assert Catalog.match_domain("teamviewer.com") == :nomatch
      assert Catalog.match_domain("net.anydesk.com") == :nomatch
      assert Catalog.match_domain("example.com") == :nomatch
      assert Catalog.match_domain("") == :nomatch
    end
  end

  describe "kev_match/1" do
    defp kev(vendor, product),
      do: %{"cveID" => "CVE-2026-0001", "vendorProject" => vendor, "product" => product}

    test "matches realistic kev records" do
      assert Catalog.kev_match(kev("N-able", "N-Central")) == ["n_central"]
      assert Catalog.kev_match(kev("N-able", "N-central")) == ["n_central"]
      assert Catalog.kev_match(kev("N-able ", " N-central ")) == ["n_central"]
      assert Catalog.kev_match(kev("ConnectWise", "ScreenConnect")) == ["screenconnect"]
      assert Catalog.kev_match(kev("ConnectWise ", "ScreenConnect ")) == ["screenconnect"]
      assert Catalog.kev_match(kev("TeamViewer", "Desktop")) == ["teamviewer"]
      assert Catalog.kev_match(kev("AnyDesk", "AnyDesk")) == ["anydesk"]
      assert Catalog.kev_match(kev("Splashtop", "Streamer")) == ["splashtop"]
      assert Catalog.kev_match(kev("NinjaOne", "Agent")) == ["ninjaone"]
      assert Catalog.kev_match(kev("N-able", "Take  Control")) == ["take_control"]
      assert Catalog.kev_match(kev("Datto", "Datto RMM")) == ["datto_rmm"]
    end

    test "does not match other products of multi-product vendors or unrelated vendors" do
      assert Catalog.kev_match(kev("SolarWinds", "Orion")) == []
      assert Catalog.kev_match(kev("SolarWinds", "Web Help Desk")) == []
      assert Catalog.kev_match(kev("Kaseya", "Virtual System/Server Administrator (VSA)")) == []
      assert Catalog.kev_match(kev("Kaseya", "VSA")) == []
      assert Catalog.kev_match(kev("ConnectWise", "Automate")) == []
      assert Catalog.kev_match(kev("ConnectWise", "Manage")) == []
      assert Catalog.kev_match(kev("N-able", "Cove Data Protection")) == []
      assert Catalog.kev_match(kev("Datto", "SIRIS")) == []
      assert Catalog.kev_match(kev("Ivanti", "Connect Secure")) == []
    end

    test "ignores records without string vendor and product" do
      assert Catalog.kev_match(%{}) == []
      assert Catalog.kev_match(%{"vendorProject" => "TeamViewer"}) == []
      assert Catalog.kev_match(%{"vendorProject" => nil, "product" => "Desktop"}) == []
    end
  end

  describe "ports/1 and cidrs/1" do
    test "returns distinct sorted ports for the given tools" do
      assert Catalog.ports(["take_control"]) == [
               %{port: 443, proto: :tcp},
               %{port: 3377, proto: :tcp}
             ]

      ports = Catalog.ports(["anydesk", "teamviewer", "bogus"])
      assert ports == Enum.uniq(ports)
      assert %{port: 7070, proto: :tcp} in ports
      assert Enum.count(ports, &(&1.port == 443)) == 1
      assert Catalog.ports([]) == []
    end

    test "cidrs are empty for the seeded tools" do
      assert Catalog.cidrs(Catalog.ids()) == []
    end
  end

  describe "loader" do
    defp json(tool), do: JSON.encode!(%{"tools" => %{"t" => tool}})

    defp base do
      %{
        "name" => "T",
        "vendor" => "V",
        "domains" => [%{"pattern" => "a.example.com", "source" => "https://example.com"}],
        "ports" => [%{"port" => 1, "proto" => "udp", "source" => "https://example.com"}],
        "cidrs" => ["192.0.2.1/32", "2001:db8::/32"],
        "kev_keys" => [%{"vendor" => "v", "product" => "*"}],
        "excluded" => []
      }
    end

    test "parses a valid tool" do
      assert [%Tool{id: "t", ports: [%{proto: :udp}], cidrs: ["192.0.2.1/32", "2001:db8::/32"]}] =
               Loader.parse!(json(base()))
    end

    test "rejects invalid entries" do
      bad = [
        put_in(base()["domains"], [%{"pattern" => "*", "source" => "x"}]),
        put_in(base()["ports"], [%{"port" => 0, "proto" => "tcp", "source" => "x"}]),
        put_in(base()["ports"], [%{"port" => 443, "proto" => "sctp", "source" => "x"}]),
        put_in(base()["cidrs"], ["192.0.2.1/33"]),
        put_in(base()["cidrs"], ["not-an-ip/32"]),
        put_in(base()["kev_keys"], [%{"vendor" => "N-able", "product" => "*"}])
      ]

      for tool <- bad do
        assert_raise ArgumentError, fn -> Loader.parse!(json(tool)) end
      end
    end
  end
end
