defmodule Breakline.Catalog.DomainPatternTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Breakline.Catalog.DomainPattern

  doctest DomainPattern

  defp m?(pattern, qname), do: DomainPattern.match?(DomainPattern.compile!(pattern), qname)

  describe "compile/1" do
    test "rejects invalid patterns" do
      assert DomainPattern.compile("") == {:error, :empty}
      assert DomainPattern.compile("*") == {:error, :bare_wildcard}
      assert DomainPattern.compile("*.com") == {:error, :suffix_too_short}
      assert DomainPattern.compile("a..com") == {:error, :empty_label}
      assert DomainPattern.compile(".a.com") == {:error, :empty_label}
      assert DomainPattern.compile("a.com.") == {:error, :empty_label}
      assert {:error, _} = DomainPattern.compile("*.")
      assert DomainPattern.compile("a.co*") == {:error, :wildcard_tld}
      assert DomainPattern.compile("a.*") == {:error, :wildcard_tld}
      assert DomainPattern.compile("a b.com") == {:error, :invalid_character}
      assert DomainPattern.compile("a/b.com") == {:error, :invalid_character}

      assert DomainPattern.compile(String.duplicate("a", 64) <> ".com") ==
               {:error, :label_too_long}
    end

    test "accepts the catalog forms" do
      assert {:ok, %DomainPattern{kind: :exact}} = DomainPattern.compile("boot.net.anydesk.com")
      assert {:ok, %DomainPattern{kind: :subdomains}} = DomainPattern.compile("*.teamviewer.com")

      assert {:ok, %DomainPattern{kind: :exact}} =
               DomainPattern.compile("relay-*.net.anydesk.com")

      assert {:ok, %DomainPattern{kind: :exact}} = DomainPattern.compile("remote.management")
    end

    test "compile! raises on invalid patterns" do
      assert_raise ArgumentError, fn -> DomainPattern.compile!("*") end
    end
  end

  describe "match?/2" do
    test "exact patterns match only themselves" do
      assert m?("boot.net.anydesk.com", "boot.net.anydesk.com")
      assert m?("boot.net.anydesk.com", "BOOT.Net.AnyDesk.COM")
      assert m?("boot.net.anydesk.com", "boot.net.anydesk.com.")
      refute m?("boot.net.anydesk.com", "boot.net.anydesk.com..")
      refute m?("boot.net.anydesk.com", "x.boot.net.anydesk.com")
      refute m?("boot.net.anydesk.com", "net.anydesk.com")
      refute m?("boot.net.anydesk.com", "boot.net.anydesk.co")
      refute m?("boot.net.anydesk.com", "")
    end

    test "leading wildcard matches one or more labels but not the suffix" do
      assert m?("*.teamviewer.com", "router15.teamviewer.com")
      assert m?("*.teamviewer.com", "a.b.c.teamviewer.com")
      assert m?("*.teamviewer.com", "Client.TeamViewer.com.")
      refute m?("*.teamviewer.com", "teamviewer.com")
      refute m?("*.teamviewer.com", "teamviewer.com.")
      refute m?("*.teamviewer.com", "eviltteamviewer.com")
      refute m?("*.teamviewer.com", "teamviewer.com.evil.net")
      refute m?("*.teamviewer.com", ".teamviewer.com")
    end

    test "mid-label wildcard stays inside one label" do
      assert m?("relay-*.net.anydesk.com", "relay-.net.anydesk.com")
      assert m?("relay-*.net.anydesk.com", "relay-12ab.net.anydesk.com")
      refute m?("relay-*.net.anydesk.com", "relay-1.x.net.anydesk.com")
      refute m?("relay-*.net.anydesk.com", "relay.net.anydesk.com")
      refute m?("relay-*.net.anydesk.com", "x.relay-1.net.anydesk.com")

      assert m?("instance-*-relay.screenconnect.com", "instance-abc123-relay.screenconnect.com")
      assert m?("instance-*-relay.screenconnect.com", "instance--relay.screenconnect.com")
      refute m?("instance-*-relay.screenconnect.com", "instance-relay.screenconnect.com")
      refute m?("instance-*-relay.screenconnect.com", "instance-a.b-relay.screenconnect.com")
    end

    test "several wildcards in one label" do
      assert m?("a*b*c.example.com", "abc.example.com")
      assert m?("a*b*c.example.com", "axxbyyc.example.com")
      refute m?("a*b*c.example.com", "acb.example.com")
      assert m?("a**c.example.com", "ac.example.com")
      refute m?("a*a.example.com", "a.example.com")
    end

    test "leading wildcard combined with a mid-label wildcard" do
      assert m?("*.relay-*.example.com", "x.relay-9.example.com")
      refute m?("*.relay-*.example.com", "relay-9.example.com")
    end
  end

  # generators

  defp label_gen do
    gen all(
          first <- StreamData.member_of(Enum.concat([?a..?z, ?0..?9])),
          rest <-
            StreamData.list_of(StreamData.member_of(Enum.concat([?a..?z, ?0..?9, [?-]])),
              max_length: 10
            )
        ) do
      List.to_string([first | rest])
    end
  end

  defp name_gen(min, max) do
    gen all(labels <- StreamData.list_of(label_gen(), min_length: min, max_length: max)) do
      Enum.join(labels, ".")
    end
  end

  defp randomise_case(name, flips) do
    name
    |> String.graphemes()
    |> Enum.zip(Stream.cycle(flips))
    |> Enum.map_join(fn {g, up?} -> if up?, do: String.upcase(g), else: g end)
  end

  describe "properties" do
    property "an exact pattern matches only itself, modulo case and one trailing dot" do
      check all(
              pattern <- name_gen(2, 5),
              other <- name_gen(1, 6)
            ) do
        compiled = DomainPattern.compile!(pattern)
        assert DomainPattern.match?(compiled, pattern)
        assert DomainPattern.match?(compiled, pattern <> ".")
        assert DomainPattern.match?(compiled, other) == (other == pattern)
        refute DomainPattern.match?(compiled, "x." <> pattern)
        refute DomainPattern.match?(compiled, pattern <> "..")
      end
    end

    property "*.x.y never matches x.y but matches any name under it" do
      check all(
              suffix <- name_gen(2, 4),
              prefix <- name_gen(1, 3)
            ) do
        compiled = DomainPattern.compile!("*." <> suffix)
        refute DomainPattern.match?(compiled, suffix)
        refute DomainPattern.match?(compiled, suffix <> ".")
        assert DomainPattern.match?(compiled, prefix <> "." <> suffix)
      end
    end

    property "a mid-label wildcard never crosses a dot" do
      check all(
              before <- label_gen(),
              filler <- name_gen(1, 3),
              suffix <- name_gen(2, 3)
            ) do
        compiled = DomainPattern.compile!(before <> "*." <> suffix)
        dots_in_filler = filler |> String.graphemes() |> Enum.count(&(&1 == "."))
        expected = dots_in_filler == 0
        assert DomainPattern.match?(compiled, before <> filler <> "." <> suffix) == expected
      end
    end

    property "matching is case-insensitive in both pattern and query" do
      check all(
              name <- name_gen(2, 5),
              flips_a <- StreamData.list_of(StreamData.boolean(), min_length: 1, max_length: 8),
              flips_b <- StreamData.list_of(StreamData.boolean(), min_length: 1, max_length: 8),
              wildcard? <- StreamData.boolean()
            ) do
        pattern = if wildcard?, do: "*." <> name, else: name
        query = if wildcard?, do: "host." <> name, else: name
        compiled = DomainPattern.compile!(randomise_case(pattern, flips_a))
        assert DomainPattern.match?(compiled, randomise_case(query, flips_b))
      end
    end
  end
end
