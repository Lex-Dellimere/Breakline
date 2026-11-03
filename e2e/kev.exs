# full-stack check: one test cisa kev entry, run inside the cloud release with `bin/cloud rpc`.
# it goes through the poller a real poll uses (fetch, parse, record, act), with req's :plug
# option standing in for cisa's server, so nothing here exists only for the demo. the real
# feed is never fetched.
#
# the first fetch of a feed is its baseline and acts on nothing (d30), so a fresh database
# first gets a baseline of an empty catalogue, then the entry
alias Cloud.Advisories.Poller

tenant = Cloud.Accounts.get_tenant_by_slug!("demo-clinic", authorize?: false)
unless tenant.advisory_mode == :auto_lock, do: raise("demo tenant is #{tenant.advisory_mode}, not auto_lock")

entry = %{
  "cveID" => "CVE-2099-0001",
  "vendorProject" => "AnyDesk",
  "product" => "AnyDesk",
  "vulnerabilityName" => "Breakline demo: test entry, not a real vulnerability",
  "dateAdded" => Date.to_iso8601(Date.utc_today()),
  "shortDescription" => "A made-up entry injected for the Breakline demo video.",
  "requiredAction" => "None, this is a test entry.",
  "knownRansomwareCampaignUse" => "Unknown"
}

feed = fn vulns ->
  body = Jason.encode!(%{"title" => "CISA Catalog of Known Exploited Vulnerabilities", "vulnerabilities" => vulns})
  [plug: fn conn -> Plug.Conn.send_resp(conn, 200, body) end, retry: false]
end

if Cloud.Advisories.ensure_feed!(:kev, authorize?: false).baseline_at == nil do
  {:ok, %{baseline?: true}} = Poller.poll(:kev, req_options: feed.([]))
end

{:ok, summary} = Poller.poll(:kev, req_options: feed.([entry]))
IO.puts("KEV new=#{summary.new} acted=#{inspect(Enum.map(summary.acted, & &1.status))}")
unless Enum.any?(summary.acted, &(&1.status == :locked)), do: raise("nothing locked")
