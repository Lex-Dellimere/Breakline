defmodule Cloud.Notifications.WorkerTest do
  # app env changes (notifications key) and the global dev sms adapter
  use Cloud.DataCase, async: false
  use Oban.Testing, repo: Cloud.Repo

  import Cloud.Fixtures
  import Cloud.NotificationFixtures
  import Swoosh.TestAssertions

  alias Cloud.Notifications
  alias Cloud.Notifications.{Event, Message, Vault, Worker}
  alias Cloud.Notifications.SMS.Dev, as: DevSMS

  @moduletag :capture_log

  @event_types Event.types()

  setup do
    org = org!()
    site = site!(org.tenant, org.admin, %{name: "Parramatta clinic"})

    advisory =
      Ash.Seed.seed!(Cloud.Advisories.Advisory, %{
        source: :kev,
        external_id: "CVE-2026-18577",
        title: "N-able N-central authentication bypass",
        cves: ["CVE-2026-18577"],
        first_seen_at: DateTime.utc_now()
      })

    contact =
      Cloud.Sites.create_msp_contact!(
        %{name: "Acme", email: "jo-#{unique()}@acme.example"},
        actor: org.admin,
        tenant: org.tenant
      )

    DevSMS.clear()
    Map.merge(org, %{site: site, advisory: advisory, contact: contact})
  end

  defp event(ctx, type) do
    %{
      type: type,
      tenant_id: ctx.tenant.id,
      site_id: ctx.site.id,
      advisory_id: ctx.advisory.id,
      msp_contact_id: ctx.contact.id
    }
  end

  # queues the event and runs its job for `channel`, returns {result, delivery}
  defp run(ctx, channel, type, opts \\ []) do
    {:ok, deliveries} = Notifications.dispatch(event(ctx, type))
    delivery = Enum.find(deliveries, &(&1.channel_id == channel.id))
    result = perform(ctx, delivery, type, opts)
    {result, reload(ctx, delivery)}
  end

  defp perform(ctx, delivery, type, opts) do
    perform_job(
      Worker,
      %{
        "delivery_id" => delivery.id,
        "tenant_id" => ctx.tenant.id,
        "event" => Event.to_args(event(ctx, type))
      },
      opts
    )
  end

  defp reload(ctx, delivery),
    do: Notifications.get_delivery!(delivery.id, tenant: ctx.tenant, authorize?: false)

  defp base, do: CloudWeb.Endpoint.url()

  describe "slack" do
    test "posts one plain line with a link and marks the delivery sent", ctx do
      stub_webhooks(200)
      channel = channel!(ctx.tenant, ctx.admin)

      {:ok, delivery} = run(ctx, channel, :advisory_locked)

      assert delivery.status == :sent
      assert delivery.attempts == 1
      assert delivery.sent_at
      assert delivery.last_error == nil

      assert_received {:webhook, "hooks.slack.com", "/services/T0ABC1234/B0DEF5678/" <> _, "",
                       payload}

      assert payload == %{
               "text" =>
                 "Breakline: Parramatta clinic was locked by advisory CISA KEV CVE-2026-18577. " <>
                   "Review: #{base()}/advisories"
             }
    end

    test "a window request names the msp and links to the requests page", ctx do
      stub_webhooks(200)
      channel = channel!(ctx.tenant, ctx.admin)
      {:ok, _} = run(ctx, channel, :window_requested)

      assert_received {:webhook, _, _, _, %{"text" => text}}

      assert text ==
               "Breakline: MSP Acme requested a window for Parramatta clinic. Review: #{base()}/requests"
    end
  end

  test "teams gets one adaptive card with a single text block and no actions", ctx do
    stub_webhooks(202)
    channel = channel!(ctx.tenant, ctx.admin, %{kind: :teams})
    {:ok, delivery} = run(ctx, channel, :break_glass_opened)
    assert delivery.status == :sent

    assert_received {:webhook, host, "/powerautomate/automations/direct/" <> _, query, payload}
    assert host =~ ~r/\.environment\.api\.powerplatform\.com$/
    assert query =~ "sig="

    assert %{
             "type" => "message",
             "attachments" => [
               %{
                 "contentType" => "application/vnd.microsoft.card.adaptive",
                 "content" =>
                   %{"type" => "AdaptiveCard", "body" => [%{"type" => "TextBlock"} = block]} =
                     card
               }
             ]
           } = payload

    refute Map.has_key?(card, "actions")
    refute Map.has_key?(block, "selectAction")
    url = "#{base()}/sites/#{ctx.site.id}"

    assert block["text"] ==
             "Breakline: break-glass access was opened for Parramatta clinic. Review: [#{url}](#{url})"
  end

  test "email goes out as plain text and simple html with the same line", ctx do
    channel = channel!(ctx.tenant, ctx.admin, %{kind: :email, target: "ops@example.com"})
    {:ok, delivery} = run(ctx, channel, :advisory_pending)
    assert delivery.status == :sent

    assert_email_sent(fn email ->
      assert email.to == [{"", "ops@example.com"}]

      assert email.subject =~
               "Breakline: Advisory CISA KEV CVE-2026-18577 affects Parramatta clinic"

      assert email.text_body ==
               "Breakline: advisory CISA KEV CVE-2026-18577 affects Parramatta clinic and needs a decision. " <>
                 "Review: #{base()}/advisories\n"

      assert email.html_body =~ ~s(<a href="#{base()}/advisories">#{base()}/advisories</a>)
      refute email.html_body =~ ~r/<(button|form|input|script)/i
      true
    end)
  end

  test "sms goes to the dev adapter", ctx do
    channel = channel!(ctx.tenant, ctx.admin, %{kind: :sms})
    {:ok, delivery} = run(ctx, channel, :window_approved)
    assert delivery.status == :sent

    assert [%{to: "+61412345678", body: body}] = DevSMS.messages()

    assert body ==
             "Breakline: a window for Parramatta clinic was approved. Review: #{base()}/requests"
  end

  test "fallback email reaches each admin and approver", ctx do
    {:ok, deliveries} = Notifications.dispatch(event(ctx, :advisory_locked))
    assert length(deliveries) == 2

    for delivery <- deliveries do
      assert :ok = perform(ctx, delivery, :advisory_locked, [])
      assert reload(ctx, delivery).status == :sent
    end

    for user <- [ctx.admin, ctx.approver] do
      address = to_string(user.email)
      assert_email_sent(to: [{"", address}])
    end
  end

  describe "failures" do
    test "a 5xx is retried, recorded and given up after the last attempt", ctx do
      stub_webhooks(503)
      channel = channel!(ctx.tenant, ctx.admin)
      {:ok, [delivery]} = Notifications.dispatch(event(ctx, :advisory_locked)) |> only(channel)

      for attempt <- 1..4 do
        assert {:error, "http status 503"} =
                 perform(ctx, delivery, :advisory_locked, attempt: attempt)

        delivery = reload(ctx, delivery)
        assert delivery.status == :pending
        assert delivery.attempts == attempt
        assert delivery.last_error == "http status 503"
      end

      assert {:error, _} = perform(ctx, delivery, :advisory_locked, attempt: 5)
      delivery = reload(ctx, delivery)
      assert delivery.status == :failed
      assert delivery.attempts == 5
      refute delivery.last_error =~ "hooks.slack.com"
      refute delivery.last_error =~ slack_secret()
    end

    test "succeeds on a later attempt after a 5xx", ctx do
      stub_webhooks(fn n -> if n == 1, do: 500, else: 200 end)
      channel = channel!(ctx.tenant, ctx.admin)
      {:ok, [delivery]} = Notifications.dispatch(event(ctx, :advisory_locked)) |> only(channel)

      assert {:error, _} = perform(ctx, delivery, :advisory_locked, attempt: 1)
      assert :ok = perform(ctx, delivery, :advisory_locked, attempt: 2)
      delivery = reload(ctx, delivery)
      assert delivery.status == :sent
      assert delivery.attempts == 2
      assert delivery.last_error == nil
    end

    test "the worker uses 5 attempts with a growing backoff" do
      job = Worker.new(%{"delivery_id" => "x", "tenant_id" => "y"})
      assert job.changes.max_attempts == 5
      assert job.changes.queue == "notifications"

      backoffs = for n <- 1..5, do: Worker.backoff(%Oban.Job{attempt: n})
      assert backoffs == Enum.sort(backoffs)
      assert hd(backoffs) >= 30
    end

    test "a removed webhook (4xx) fails at once", ctx do
      stub_webhooks(404)
      channel = channel!(ctx.tenant, ctx.admin)
      assert {{:cancel, "http status 404"}, delivery} = run(ctx, channel, :advisory_locked)
      assert delivery.status == :failed
    end

    test "a redirect is not followed", ctx do
      test = self()

      Req.Test.stub(Cloud.Notifications.Webhook, fn conn ->
        send(test, {:webhook_path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data")
        |> Plug.Conn.send_resp(302, "")
      end)

      channel = channel!(ctx.tenant, ctx.admin)

      assert {{:error, "http status 302"}, %{status: :pending}} =
               run(ctx, channel, :advisory_locked)

      assert_received {:webhook_path, "/services/" <> _}
      refute_received {:webhook_path, _}
    end

    test "a 429 is retried", ctx do
      stub_webhooks(429)
      channel = channel!(ctx.tenant, ctx.admin)
      assert {{:error, _}, %{status: :pending}} = run(ctx, channel, :advisory_locked)
    end

    test "a disabled or removed channel is not contacted", ctx do
      stub_webhooks(200)
      channel = channel!(ctx.tenant, ctx.admin)
      {:ok, [delivery]} = Notifications.dispatch(event(ctx, :advisory_locked)) |> only(channel)

      Notifications.set_channel_enabled!(channel, false, actor: ctx.admin, tenant: ctx.tenant)
      assert {:cancel, "channel is disabled"} = perform(ctx, delivery, :advisory_locked, [])

      other = channel!(ctx.tenant, ctx.admin)
      {:ok, [delivery]} = Notifications.dispatch(event(ctx, :advisory_locked)) |> only(other)
      :ok = Notifications.destroy_channel!(other, actor: ctx.admin, tenant: ctx.tenant)
      assert {:cancel, "channel was removed"} = perform(ctx, delivery, :advisory_locked, [])
      assert reload(ctx, delivery).status == :failed
      assert reload(ctx, delivery).channel_id == nil
      refute_received {:webhook, _, _, _, _}
    end

    test "a channel whose key changed fails instead of sending", ctx do
      channel = channel!(ctx.tenant, ctx.admin)
      Application.put_env(:cloud, :notifications_key, String.duplicate("k", 40))

      try do
        assert {{:cancel, message}, %{status: :failed}} = run(ctx, channel, :advisory_locked)
        assert message =~ "cannot be decrypted"
      after
        Application.delete_env(:cloud, :notifications_key)
      end
    end
  end

  test "a dedicated notifications key replaces the secret key base" do
    ciphertext = Vault.encrypt("hello")
    Application.put_env(:cloud, :notifications_key, String.duplicate("k", 40))

    try do
      assert :error = Vault.decrypt(ciphertext)
      assert {:ok, "hello"} = "hello" |> Vault.encrypt() |> Vault.decrypt()
    after
      Application.delete_env(:cloud, :notifications_key)
    end

    assert {:ok, "hello"} = Vault.decrypt(ciphertext)
  end

  test "send test posts a link to the site list, even on a disabled channel", ctx do
    stub_webhooks(200)
    channel = channel!(ctx.tenant, ctx.admin)
    Notifications.set_channel_enabled!(channel, false, actor: ctx.admin, tenant: ctx.tenant)
    {:ok, delivery} = Notifications.send_test(ctx.tenant.id, channel.id, actor: ctx.admin)
    assert delivery.event_type == :test

    assert [job] = all_enqueued(worker: Worker)
    assert :ok = perform_job(Worker, job.args)
    assert_received {:webhook, _, _, _, %{"text" => text}}

    assert text ==
             "Breakline: this is a test notification for #{ctx.tenant.name}. Sites: #{base()}/sites"
  end

  describe "every payload" do
    test "carries the app link and no button, action or token", ctx do
      for type <- [:test | @event_types] do
        message = Message.build(event(ctx, type))
        assert String.starts_with?(message.url, base() <> "/")
        uri = URI.parse(message.url)
        assert uri.query == nil
        assert uri.path in ["/advisories", "/requests", "/sites", "/sites/#{ctx.site.id}"]

        payloads = [
          Jason.encode!(Message.slack(message)),
          Jason.encode!(Message.teams(message)),
          Jason.encode!(Message.email(message)),
          Message.sms(message)
        ]

        for payload <- payloads do
          assert payload =~ message.url
          refute payload =~ ~r/token|secret|approve\?|\/auth\//i
          refute payload =~ ~r/"actions"|Action\.|selectAction|"blocks"|"button"|accessory/
          refute payload =~ ~r/<(button|form|input)/i
        end

        assert Map.keys(Message.slack(message)) == ["text"]
      end
    end

    test "names from users cannot smuggle links or mentions in", ctx do
      evil = "<https://evil.example|Approve now> [click](https://evil.example) <!channel> *bold*"
      site = site!(ctx.tenant, ctx.admin, %{name: evil})

      message =
        Message.build(%{type: :break_glass_opened, tenant_id: ctx.tenant.id, site_id: site.id})

      slack = Message.slack(message)["text"]
      refute slack =~ "<https"
      refute slack =~ "<!channel>"
      refute slack =~ "|"

      [%{"content" => %{"body" => [%{"text" => teams}]}}] = Message.teams(message)["attachments"]
      refute teams =~ "[click]"
      refute teams =~ "](https://evil"

      refute Message.email(message).html =~ "<https"
    end

    test "a site of another tenant is never named", ctx do
      other = org!()
      other_site = site!(other.tenant, other.admin, %{name: "Somebody else's site"})

      message =
        Message.build(%{
          type: :break_glass_opened,
          tenant_id: ctx.tenant.id,
          site_id: other_site.id
        })

      refute Message.line(message) =~ "Somebody"
    end
  end

  defp only({:ok, deliveries}, channel),
    do: {:ok, Enum.filter(deliveries, &(&1.channel_id == channel.id))}
end
