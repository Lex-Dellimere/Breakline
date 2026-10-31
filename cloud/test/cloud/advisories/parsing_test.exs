defmodule Cloud.Advisories.ParsingTest do
  use ExUnit.Case, async: true

  import Cloud.AdvisoryFeeds

  alias Cloud.Advisories.{ACSC, KEV, TextMatch}

  doctest Cloud.Advisories.TextMatch
  doctest Cloud.Advisories.ACSC

  describe "cves" do
    test "accepts the dash, space and mixed forms" do
      assert TextMatch.cves("CVE-2026-1234") == ["CVE-2026-1234"]
      assert TextMatch.cves("CVE 2026 1234") == ["CVE-2026-1234"]
      assert TextMatch.cves("CVE-2026 1234") == ["CVE-2026-1234"]
      assert TextMatch.cves("cve 2026-1234") == ["CVE-2026-1234"]

      assert TextMatch.cves("mitigations for CVE 2026 63077 (Critical, 9.8).") == [
               "CVE-2026-63077"
             ]

      assert TextMatch.cves("CVE-2026-118527, CVE-2026-118527") == ["CVE-2026-118527"]
    end

    test "rejects things that are not cves" do
      assert TextMatch.cves("CVE-26-1234") == []
      assert TextMatch.cves("CVE-2026-123") == []
      assert TextMatch.cves("XCVE-2026-1234") == []
      assert TextMatch.cves("CVE-2026-12345678") == []
      assert TextMatch.cves("version 2026 1234") == []
    end
  end

  describe "tool names" do
    test "match the catalog names as whole words, ignoring case" do
      assert TextMatch.tool_ids("Active exploitation of N-able and N-central vulnerabilities") ==
               ["n_central"]

      assert TextMatch.tool_ids("ConnectWise ScreenConnect 23.9.8") == ["screenconnect"]
      assert TextMatch.tool_ids("screenconnect's relay") == ["screenconnect"]
      assert TextMatch.tool_ids("ANYDESK and TeamViewer") == ["anydesk", "teamviewer"]
      assert TextMatch.tool_ids("Splashtop Streamer") == ["splashtop"]
      assert TextMatch.tool_ids("NinjaOne agents") == ["ninjaone"]
      assert TextMatch.tool_ids("the Datto RMM agent") == ["datto_rmm"]
      assert TextMatch.tool_ids("N-able Take Control viewer") == ["take_control"]
    end

    test "do not match on generic words or other products" do
      for text <- [
            "attackers take control of the server",
            "Take Control of your cyber security",
            "remote monitoring and management (RMM) platforms",
            "an RMM tool",
            "N-able Cove backup",
            "N-able N-sight",
            "ConnectWise Automate and ConnectWise PSA",
            "Datto backup appliances",
            "Kaseya VSA",
            "SolarWinds Orion",
            "AnyDesktop is not a product",
            "TeamViewers",
            "NinjaOneX",
            "superscreenconnect",
            "Critical vulnerabilities in Fortinet products"
          ] do
        assert TextMatch.tool_ids(text) == [], "matched #{inspect(text)}"
      end
    end

    test "names are derived from the catalog" do
      names = Map.new(TextMatch.names())
      assert names["n_central"] == ["N-able N-central", "N-central"]
      assert names["take_control"] == ["N-able Take Control"]
      assert names["datto_rmm"] == ["Datto RMM"]
      assert names["anydesk"] == ["AnyDesk"]
      assert names["screenconnect"] == ["ConnectWise ScreenConnect", "ScreenConnect"]
    end
  end

  describe "exploitation" do
    test "reads the signals" do
      assert TextMatch.exploitation("Active exploitation of a platform", "") == :active

      assert TextMatch.exploitation(
               "Critical vulnerabilities in Fortinet products",
               "ASD’s ACSC is currently not aware of active exploitation related to these vulnerabilities"
             ) == :not_known

      assert TextMatch.exploitation("Critical vulnerabilities in PHP", "a security release") ==
               :unknown

      assert TextMatch.exploitation("Citrix", "vulnerabilities, under active exploitation") ==
               :active
    end
  end

  describe "kev" do
    test "parses the feed and matches tools with the catalog keys" do
      assert {:ok, entries} = KEV.parse(fixture("kev.json"))
      by_cve = Map.new(entries, &{&1.external_id, &1})
      assert map_size(by_cve) == 8

      assert by_cve["CVE-2026-18556"].tool_ids == ["n_central"]
      assert by_cve["CVE-2025-8875"].product == "N-Central"
      assert by_cve["CVE-2025-8875"].tool_ids == ["n_central"]
      assert by_cve["CVE-2024-1709"].tool_ids == ["screenconnect"]
      assert by_cve["CVE-2019-18988"].tool_ids == ["teamviewer"]
      assert by_cve["CVE-2020-10148"].tool_ids == []
      assert by_cve["CVE-2021-30116"].tool_ids == []
      assert by_cve["CVE-2026-63077"].tool_ids == []

      entry = by_cve["CVE-2026-18556"]
      assert entry.cves == ["CVE-2026-18556"]
      assert entry.exploitation == :active
      assert entry.published_at == ~U[2026-08-04 00:00:00.000000Z]
      assert entry.title =~ "N-able N-central"
      assert entry.raw["cveID"] == "CVE-2026-18556"
    end

    test "normalises messy vendor strings and skips malformed entries" do
      body =
        Jason.encode!(%{
          "vulnerabilities" => [
            kev_vuln("CVE-2026-1", "N-able", "N-central"),
            kev_vuln(" CVE-2026-55555 ", "  N-able ", " N-Central  "),
            %{"product" => "no id"}
          ]
        })

      assert {:ok, [entry]} = KEV.parse(body)
      assert entry.external_id == "CVE-2026-55555"
      assert entry.vendor == "N-able"
      assert entry.tool_ids == ["n_central"]
    end

    test "rejects a document that is not the catalogue" do
      assert {:error, :unexpected_document} = KEV.parse(~s({"foo": 1}))
      assert {:error, {:invalid_json, _}} = KEV.parse("<html>")
    end
  end

  describe "acsc" do
    test "parses the real alerts and dedupes by title" do
      assert {:ok, entries} = ACSC.parse(fixture("acsc_alerts.xml"), :acsc_alerts)
      by_id = Map.new(entries, &{&1.external_id, &1})
      assert map_size(by_id) == 4

      n_central =
        by_id["active-exploitation-of-remote-monitoring-and-management-platform-within-australia"]

      assert n_central.tool_ids == ["n_central"]
      assert n_central.cves == ["CVE-2026-18556", "CVE-2026-18577"]
      assert n_central.exploitation == :active
      assert n_central.published_at == ~U[2026-08-19 04:44:29.000000Z]
      assert n_central.raw["creator"] == "Australian Cyber Security Centre (ACSC)"
      assert n_central.raw["feed"] == "acsc_alerts"

      teamcity = by_id["active-exploitation-of-a-software-development-platform-within-australia"]
      assert teamcity.cves == ["CVE-2026-63077"]
      assert teamcity.tool_ids == []

      assert teamcity.link ==
               "https://www.cyber.gov.au/alert/active-exploitation-of-a-software-development-platform-within-australia"

      fortinet = by_id["critical-vulnerabilities-in-fortinet-products"]
      assert fortinet.tool_ids == []
      assert fortinet.cves == []
      assert fortinet.exploitation == :not_known
    end

    test "parses the advisories feed" do
      assert {:ok, [_, _] = entries} =
               ACSC.parse(fixture("acsc_advisories.xml"), :acsc_advisories)

      assert Enum.all?(entries, &(&1.tool_ids == [] and &1.source == :acsc))
    end

    test "matches names in the description and strips markup" do
      body =
        rss([
          %{
            title: "Vulnerability in a remote access tool",
            link: "https://www.cyber.gov.au/alert/a",
            description: "<p>Update <strong>AnyDesk</strong> now, see CVE-2026 4242.</p>"
          }
        ])

      assert {:ok, [entry]} = ACSC.parse(body, :acsc_alerts)
      assert entry.tool_ids == ["anydesk"]
      assert entry.cves == ["CVE-2026-4242"]
    end

    test "refuses entity declarations and bad xml" do
      evil = """
      <?xml version="1.0"?>
      <!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]>
      <rss><channel><item><title>&x;</title></item></channel></rss>
      """

      assert {:error, {:invalid_xml, _}} = ACSC.parse(evil, :acsc_alerts)
      assert {:error, {:invalid_xml, _}} = ACSC.parse("<rss><channel>", :acsc_alerts)
      assert {:error, {:invalid_xml, _}} = ACSC.parse("not xml", :acsc_alerts)
    end

    test "reads rss dates" do
      assert ACSC.pub_date("Fri, 23 Oct 2026 16:11:47 +1100") == ~U[2026-10-23 05:11:47.000000Z]
      assert ACSC.pub_date("23 Oct 2026 05:11 GMT") == ~U[2026-10-23 05:11:00.000000Z]
      assert ACSC.pub_date("yesterday") == nil
      assert ACSC.pub_date(nil) == nil
    end
  end
end
