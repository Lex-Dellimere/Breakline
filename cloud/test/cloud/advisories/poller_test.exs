defmodule Cloud.Advisories.PollerTest do
  use Cloud.DataCase, async: true

  # failed polls log a warning
  @moduletag :capture_log

  import Cloud.AdvisoryFeeds
  import Cloud.Fixtures

  alias Cloud.{Accounts, Advisories, Policies, Sites}

  @trusted [authorize?: false]

  setup do
    auto = org!()
    ask = org!()
    Accounts.update_tenant_settings!(ask.tenant, %{advisory_mode: :ask}, @trusted)

    %{
      auto: auto,
      ask: ask,
      n_central:
        site!(auto.tenant, auto.admin, %{name: "auto n-central", tool_ids: ["n_central"]}),
      datto: site!(auto.tenant, auto.admin, %{name: "auto datto", tool_ids: ["datto_rmm"]}),
      screenconnect:
        site!(auto.tenant, auto.admin, %{name: "auto screenconnect", tool_ids: ["screenconnect"]}),
      ask_n_central:
        site!(ask.tenant, ask.admin, %{name: "ask n-central", tool_ids: ["n_central", "anydesk"]})
    }
  end

  defp site_advisories(site) do
    Advisories.list_site_advisories!(
      [tenant: site.tenant_id, query: [filter: [site_id: site.id], load: [:advisory]]] ++
        @trusted
    )
  end

  defp locks(site) do
    Sites.list_advisory_locks!(
      [tenant: site.tenant_id, query: [filter: [site_id: site.id]]] ++ @trusted
    )
  end

  defp published_version(site) do
    case Policies.latest_policy_version(site.id) do
      {:ok, version} -> version.version
      {:error, :not_published} -> 0
    end
  end

  defp baseline_kev!(opts \\ []) do
    serve(%{kev: kev_json(opts)})
    assert {:ok, %{status: :ok, baseline?: true, acted: []}} = Advisories.poll(:kev)
  end

  describe "baseline" do
    test "the first fetch records every entry as seen and acts on nothing", ctx do
      serve(%{kev: kev_json()})
      assert {:ok, summary} = Advisories.poll(:kev)
      assert %{status: :ok, baseline?: true, entries: 8, new: 8, acted: []} = summary

      advisories = Advisories.list_advisories!(@trusted)
      assert length(advisories) == 8
      assert Enum.all?(advisories, & &1.baseline?)

      for site <- [ctx.n_central, ctx.screenconnect, ctx.ask_n_central] do
        assert site_advisories(site) == []
        assert locks(site) == []
      end

      [feed] = Advisories.list_feeds!(@trusted)
      assert feed.name == :kev
      assert feed.baseline_at
      assert feed.last_status == "ok"
      assert feed.etag
    end

    test "the acsc baseline acts on nothing either", ctx do
      serve(%{acsc_alerts: fixture("acsc_alerts.xml")})
      assert {:ok, %{baseline?: true, acted: []}} = Advisories.poll(:acsc_alerts)
      assert site_advisories(ctx.n_central) == []
    end
  end

  describe "a new kev entry" do
    setup do
      baseline_kev!(drop: ["CVE-2026-18556"])
      :ok
    end

    test "locks matching sites of auto_lock tenants and publishes", ctx do
      Phoenix.PubSub.subscribe(Cloud.PubSub, Advisories.notifications_topic(ctx.auto.tenant.id))
      Phoenix.PubSub.subscribe(Cloud.PubSub, Policies.topic(ctx.n_central.id))

      serve(%{kev: kev_json()})
      assert {:ok, %{status: :ok, baseline?: false, new: 1, acted: acted}} = Advisories.poll(:kev)

      assert Enum.sort(Enum.map(acted, &{&1.site_id, &1.status})) ==
               Enum.sort([{ctx.n_central.id, :locked}, {ctx.ask_n_central.id, :pending}])

      assert [%{status: :locked, advisory: advisory} = sa] = site_advisories(ctx.n_central)
      assert advisory.external_id == "CVE-2026-18556"
      assert sa.decided_at
      assert sa.decided_by_id == nil

      assert [lock] = locks(ctx.n_central)
      assert lock.id == sa.advisory_lock_id
      assert lock.source == "kev:CVE-2026-18556"
      assert lock.reason =~ "CISA KEV CVE-2026-18556: N-able N-central"
      assert lock.expires_at == nil

      version = published_version(ctx.n_central)
      assert version == 1
      {:ok, pv} = Policies.latest_policy_version(ctx.n_central.id)
      assert [%{"source" => "kev:CVE-2026-18556"}] = pv.policy["advisory_locks"]

      assert_receive {:policy_published, site_id, ^version} when site_id == ctx.n_central.id
      site_id = ctx.n_central.id
      tenant_id = ctx.auto.tenant.id

      assert_receive {:advisory,
                      %{tenant_id: ^tenant_id, site_id: ^site_id, status: :locked, advisory_id: _}}
    end

    test "leaves sites with other tools alone", ctx do
      serve(%{kev: kev_json()})
      assert {:ok, _} = Advisories.poll(:kev)

      for site <- [ctx.datto, ctx.screenconnect] do
        assert site_advisories(site) == []
        assert locks(site) == []
        assert published_version(site) == 0
      end
    end

    test "asks in tenants set to ask, without locking", ctx do
      Phoenix.PubSub.subscribe(Cloud.PubSub, Advisories.notifications_topic(ctx.ask.tenant.id))
      serve(%{kev: kev_json()})
      assert {:ok, _} = Advisories.poll(:kev)

      assert [%{status: :pending, advisory_lock_id: nil, decided_at: nil}] =
               site_advisories(ctx.ask_n_central)

      assert locks(ctx.ask_n_central) == []
      assert published_version(ctx.ask_n_central) == 0
      assert_receive {:advisory, %{status: :pending}}
    end

    test "is idempotent", ctx do
      serve(%{kev: kev_json()})
      assert {:ok, %{acted: [_, _]}} = Advisories.poll(:kev)
      assert {:ok, %{new: 0, acted: []}} = Advisories.poll(:kev)

      # even when an advisory is acted on again, for example after a crash
      [advisory] =
        Advisories.list_advisories!(
          [query: [filter: [external_id: "CVE-2026-18556"]]] ++ @trusted
        )

      assert {:ok, []} = Cloud.Advisories.Responder.act(advisory)

      assert [_] = site_advisories(ctx.n_central)
      assert [_] = locks(ctx.n_central)
      assert published_version(ctx.n_central) == 1
    end
  end

  test "kev entries for other products never touch datto or n-central sites", ctx do
    baseline_kev!(drop: ["CVE-2020-10148", "CVE-2021-30116"])
    serve(%{kev: kev_json()})
    assert {:ok, %{new: 2, acted: []}} = Advisories.poll(:kev)

    for site <- [ctx.datto, ctx.n_central, ctx.ask_n_central] do
      assert site_advisories(site) == []
      assert locks(site) == []
    end
  end

  test "a kev entry for a single-product vendor matches any of its products", ctx do
    baseline_kev!()
    serve(%{kev: kev_json(add: [kev_vuln("CVE-2026-99001", "AnyDesk ", "AnyDesk Client")])})
    assert {:ok, %{acted: [%{status: :pending}]}} = Advisories.poll(:kev)
    assert [%{status: :pending}] = site_advisories(ctx.ask_n_central)
  end

  describe "conditional get" do
    test "sends the stored validators and does nothing on 304", ctx do
      baseline_kev!(drop: ["CVE-2026-18556"])
      assert_receive {:feed_request, :kev, headers}
      refute List.keymember?(headers, "if-none-match", 0)

      [feed] = Advisories.list_feeds!(@trusted)
      serve(%{kev: :not_modified})
      assert {:ok, %{status: :not_modified, new: 0, acted: []}} = Advisories.poll(:kev)

      assert_receive {:feed_request, :kev, headers}
      assert {"if-none-match", feed.etag} in headers
      assert {"if-modified-since", "Fri, 30 Oct 2026 17:02:45 GMT"} in headers

      [after_304] = Advisories.list_feeds!(@trusted)
      assert after_304.last_status == "not_modified"
      assert after_304.etag == feed.etag
      assert site_advisories(ctx.n_central) == []
    end

    test "an error keeps the validators and fails", _ctx do
      baseline_kev!()
      [feed] = Advisories.list_feeds!(@trusted)

      serve(%{kev: {:status, 500}})
      assert {:error, {:http_status, 500}} = Advisories.poll(:kev)

      serve(%{kev: "{not json"})
      assert {:error, {:invalid_json, _}} = Advisories.poll(:kev)

      [after_error] = Advisories.list_feeds!(@trusted)
      assert after_error.last_status =~ "error: "
      assert after_error.etag == feed.etag
    end

    test "a failed first fetch is not a baseline" do
      serve(%{kev: {:status, 503}})
      assert {:error, _} = Advisories.poll(:kev)
      [feed] = Advisories.list_feeds!(@trusted)
      assert feed.baseline_at == nil
    end
  end

  describe "acsc" do
    setup do
      serve(%{acsc_alerts: rss([])})
      assert {:ok, %{baseline?: true}} = Advisories.poll(:acsc_alerts)
      :ok
    end

    test "an acsc-only match is always pending, even for auto_lock tenants", ctx do
      serve(%{acsc_alerts: fixture("acsc_alerts.xml")})
      assert {:ok, %{entries: 4, new: 4, acted: acted}} = Advisories.poll(:acsc_alerts)

      assert Enum.sort(Enum.map(acted, &{&1.site_id, &1.status})) ==
               Enum.sort([{ctx.n_central.id, :pending}, {ctx.ask_n_central.id, :pending}])

      assert [%{status: :pending, advisory: advisory}] = site_advisories(ctx.n_central)
      assert advisory.source == :acsc
      assert advisory.cves == ["CVE-2026-18556", "CVE-2026-18577"]
      assert advisory.tool_ids == ["n_central"]
      assert advisory.exploitation == :active
      assert locks(ctx.n_central) == []

      for site <- [ctx.datto, ctx.screenconnect] do
        assert site_advisories(site) == []
      end
    end

    test "duplicates under different links are one advisory" do
      serve(%{acsc_alerts: fixture("acsc_alerts.xml")})
      assert {:ok, _} = Advisories.poll(:acsc_alerts)

      teamcity =
        Advisories.list_advisories!(
          [
            query: [
              filter: [
                external_id:
                  "active-exploitation-of-a-software-development-platform-within-australia"
              ]
            ]
          ] ++
            @trusted
        )

      assert [%{cves: ["CVE-2026-63077"], tool_ids: []} = advisory] = teamcity
      # the earliest of the duplicates is kept
      assert advisory.link =~ "/alert/active-exploitation-of-a-software-development-platform"
    end

    test "the same alert in both feeds is one advisory" do
      serve(%{acsc_advisories: rss([])})
      assert {:ok, _} = Advisories.poll(:acsc_advisories)

      item = %{
        title: "Active exploitation of Splashtop",
        link: "https://www.cyber.gov.au/alert/x"
      }

      serve(%{
        acsc_alerts: rss([item]),
        acsc_advisories: rss([%{item | link: "https://www.cyber.gov.au/node/9"}])
      })

      assert {:ok, %{new: 1}} = Advisories.poll(:acsc_alerts)
      assert {:ok, %{new: 0}} = Advisories.poll(:acsc_advisories)
    end

    test "an acsc cve that kev ties to a tool matches that tool", ctx do
      baseline_kev!(drop: ["CVE-2026-18556"])
      # CVE-2026-18577 is in the kev baseline, so kev itself never acted on it
      item = %{
        title: "Vulnerabilities in an RMM platform",
        link: "https://www.cyber.gov.au/alert/rmm",
        description: "Apply the vendor patch for CVE 2026 18577."
      }

      serve(%{acsc_alerts: rss([item])})
      assert {:ok, %{acted: acted}} = Advisories.poll(:acsc_alerts)
      assert Enum.all?(acted, &(&1.status == :pending))
      assert ctx.n_central.id in Enum.map(acted, & &1.site_id)

      [%{advisory: advisory}] = site_advisories(ctx.n_central)
      assert advisory.tool_ids == ["n_central"]
      assert advisory.raw["match"] == %{"names" => [], "kev" => ["CVE-2026-18577"]}
    end

    test "skips sites a kev advisory for the same cve already raised", ctx do
      baseline_kev!(drop: ["CVE-2026-18556"])
      serve(%{kev: kev_json()})
      assert {:ok, %{acted: [_, _]}} = Advisories.poll(:kev)

      serve(%{acsc_alerts: fixture("acsc_alerts.xml")})
      assert {:ok, %{acted: []}} = Advisories.poll(:acsc_alerts)
      assert [%{status: :locked}] = site_advisories(ctx.n_central)
      assert [%{status: :pending, advisory: %{source: :kev}}] = site_advisories(ctx.ask_n_central)
    end
  end

  describe "decisions" do
    setup ctx do
      baseline_kev!(drop: ["CVE-2026-18556"])
      serve(%{kev: kev_json()})
      assert {:ok, _} = Advisories.poll(:kev)
      [pending] = site_advisories(ctx.ask_n_central)
      %{pending: pending}
    end

    test "an approver confirms the lock, which publishes", ctx do
      site = ctx.ask_n_central
      Phoenix.PubSub.subscribe(Cloud.PubSub, Policies.topic(site.id))
      Phoenix.PubSub.subscribe(Cloud.PubSub, Advisories.notifications_topic(site.tenant_id))

      assert {:ok, confirmed} =
               Advisories.confirm_lock(ctx.pending,
                 actor: ctx.ask.approver,
                 tenant: site.tenant_id
               )

      assert confirmed.status == :locked
      assert confirmed.decided_by_id == ctx.ask.approver.id
      assert confirmed.decided_at
      assert [lock] = locks(site)
      assert confirmed.advisory_lock_id == lock.id
      assert lock.source == "kev:CVE-2026-18556"
      assert published_version(site) == 1
      assert_receive {:policy_published, _, 1}
      assert_receive {:advisory, %{status: :locked}}

      {:ok, pv} = Policies.latest_policy_version(site.id)
      assert pv.published_by_id == ctx.ask.approver.id

      assert {:error, _} =
               Advisories.confirm_lock(confirmed, actor: ctx.ask.admin, tenant: site.tenant_id)

      assert [_] = locks(site)
    end

    test "dismiss leaves access as it is", ctx do
      site = ctx.ask_n_central
      Phoenix.PubSub.subscribe(Cloud.PubSub, Policies.topic(site.id))

      assert {:ok, dismissed} =
               Advisories.dismiss_site_advisory(ctx.pending,
                 actor: ctx.ask.admin,
                 tenant: site.tenant_id
               )

      assert dismissed.status == :dismissed
      assert dismissed.decided_by_id == ctx.ask.admin.id
      assert locks(site) == []
      assert published_version(site) == 0
      refute_receive {:policy_published, _, _}

      assert {:error, _} =
               Advisories.confirm_lock(dismissed, actor: ctx.ask.admin, tenant: site.tenant_id)
    end

    test "only members of the tenant can decide", ctx do
      site = ctx.ask_n_central
      outsider = org!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Advisories.confirm_lock(ctx.pending, actor: outsider.admin, tenant: site.tenant_id)

      # pointed at the outsider's own tenant, the record is simply not there
      assert {:error, %Ash.Error.Invalid{}} =
               Advisories.dismiss_site_advisory(ctx.pending,
                 actor: outsider.admin,
                 tenant: outsider.tenant.id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Advisories.record_site_advisory(
                 %{site_id: site.id, advisory_id: ctx.pending.advisory_id, status: :locked},
                 actor: ctx.ask.admin,
                 tenant: site.tenant_id
               )

      assert locks(site) == []
      assert [%{status: :pending}] = site_advisories(site)
    end

    test "members only read their own tenant's site advisories", ctx do
      assert [_] =
               Advisories.list_site_advisories!(actor: ctx.ask.approver, tenant: ctx.ask.tenant)

      assert [] =
               Advisories.list_site_advisories!(actor: ctx.ask.approver, tenant: ctx.auto.tenant)

      assert {:error, _} = Advisories.list_site_advisories(actor: ctx.ask.approver)
    end
  end
end
