defmodule Cloud.Advisories.JobsTest do
  # feeds and advisories are global rows with unique names and ids; concurrent sandbox
  # transactions inserting the same ones block on each other, so these run serially
  use Cloud.DataCase, async: false
  use Oban.Testing, repo: Cloud.Repo

  import Cloud.AdvisoryFeeds
  import Cloud.Fixtures

  alias Cloud.Advisories
  alias Cloud.Advisories.Feed.AshOban.ActionWorker.{PollAcscAdvisories, PollAcscAlerts, PollKev}

  @moduletag :capture_log

  test "each feed is polled every 30 minutes on the advisories queue" do
    config = AshOban.config([Cloud.Advisories], Application.fetch_env!(:cloud, Oban))

    crontab = config[:cron][:crontab]

    assert {"*/30 * * * *", PollKev, _} = List.keyfind(crontab, "*/30 * * * *", 0)
    assert Enum.any?(crontab, &match?({"5,35 * * * *", PollAcscAlerts, _}, &1))
    assert Enum.any?(crontab, &match?({"10,40 * * * *", PollAcscAdvisories, _}, &1))
    assert Keyword.fetch!(config[:queues], :advisories) == 1
  end

  test "the kev job polls kev" do
    %{tenant: tenant, admin: admin} = org!()
    site = site!(tenant, admin, %{tool_ids: ["n_central"]})

    serve(%{kev: kev_json(drop: ["CVE-2026-18556"])})
    assert :ok = perform_job(PollKev, %{})
    assert [%{name: :kev, baseline_at: %DateTime{}}] = Advisories.list_feeds!(authorize?: false)

    serve(%{kev: kev_json()})
    assert :ok = perform_job(PollKev, %{})

    assert [%{status: :locked}] =
             Advisories.list_site_advisories!(tenant: tenant, authorize?: false)

    assert [_] = Cloud.Sites.list_advisory_locks!(tenant: site.tenant_id, authorize?: false)
  end

  test "the acsc jobs poll their feeds" do
    serve(%{
      acsc_alerts: fixture("acsc_alerts.xml"),
      acsc_advisories: fixture("acsc_advisories.xml")
    })

    assert :ok = perform_job(PollAcscAlerts, %{})
    assert :ok = perform_job(PollAcscAdvisories, %{})

    assert Enum.sort(Enum.map(Advisories.list_feeds!(authorize?: false), & &1.name)) ==
             [:acsc_advisories, :acsc_alerts]

    assert length(Advisories.list_advisories!(authorize?: false)) == 6
  end

  test "a failed poll fails the job so oban retries it" do
    serve(%{kev: {:status, 502}})

    assert_raise Ash.Error.Unknown, ~r/poll of kev failed: \{:http_status, 502\}/, fn ->
      perform_job(PollKev, %{})
    end
  end

  test "enqueue_polls queues every feed's job" do
    Advisories.enqueue_polls()
    assert_enqueued(worker: PollKev, queue: :advisories)
    assert_enqueued(worker: PollAcscAlerts, queue: :advisories)
    assert_enqueued(worker: PollAcscAdvisories, queue: :advisories)

    serve(%{kev: kev_json(), acsc_alerts: rss([]), acsc_advisories: rss([])})
    assert %{success: 3, failure: 0} = Oban.drain_queue(queue: :advisories)
    assert length(Advisories.list_feeds!(authorize?: false)) == 3
  end
end
