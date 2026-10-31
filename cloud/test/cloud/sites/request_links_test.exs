defmodule Cloud.Sites.RequestLinksTest do
  # notification broadcasts go through the shared pubsub
  use Cloud.DataCase, async: false

  import Cloud.Fixtures
  import Swoosh.TestAssertions

  require Ash.Query

  alias Cloud.Sites
  alias Cloud.Sites.{RequestLink, RequestLinks}

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Parramatta clinic"})

    contact =
      Sites.create_msp_contact!(
        %{name: "MSP NOC #{unique()}", email: "noc-#{unique()}@msp.example"},
        actor: admin,
        tenant: tenant
      )

    Map.merge(org, %{site: site, contact: contact})
  end

  defp link!(ctx) do
    Sites.create_request_link!(%{site_id: ctx.site.id, msp_contact_id: ctx.contact.id},
      actor: ctx.admin,
      tenant: ctx.tenant
    )
  end

  # a local wall-clock time in the site's zone, `seconds` from now, on a whole minute
  defp local_in(seconds, tz \\ "Australia/Sydney") do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.shift_zone!(tz, Tz.TimeZoneDatabase)
    |> DateTime.to_naive()
    |> then(&%{&1 | second: 0, microsecond: {0, 0}})
  end

  defp request(link, attrs \\ %{}) do
    RequestLinks.request_window(
      link,
      Map.merge(
        %{starts_at: local_in(3600), ends_at: local_in(3 * 3600), reason: "INC-1 patching"},
        attrs
      )
    )
  end

  defp errors(%{errors: errors}), do: Enum.map(errors, &{&1.field, &1.message})

  describe "links" do
    test "only the hash of the token is stored and the email carries the url", ctx do
      link = link!(ctx)
      token = link.__metadata__.token
      {:ok, raw} = Base.url_decode64(token, padding: false)
      assert byte_size(raw) == 32
      assert link.token_hash == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      assert link.__metadata__.email_sent?
      assert DateTime.diff(link.expires_at, DateTime.utc_now(), :day) in [13, 14]

      # the raw token is nowhere in the row
      %{rows: [row]} =
        Repo.query!("select * from request_links where id = $1", [Ecto.UUID.dump!(link.id)])

      refute Enum.any?(row, &(is_binary(&1) and String.contains?(&1, token)))

      url = RequestLinks.request_url(token)
      assert url =~ "/request/" <> token

      assert_email_sent(fn email ->
        assert email.to == [{ctx.contact.name, to_string(ctx.contact.email)}]
        assert email.text_body =~ url
        assert email.html_body =~ url
        assert email.subject =~ "Parramatta clinic"
      end)

      assert {:ok, found} = RequestLinks.lookup(token)
      assert found.id == link.id
      assert found.site.name == "Parramatta clinic"
    end

    test "unknown, malformed, expired and revoked tokens are all just invalid", ctx do
      link = link!(ctx)
      token = link.__metadata__.token
      {other, _hash} = RequestLinks.new_token()

      assert RequestLinks.lookup(other) == {:error, :invalid}
      assert RequestLinks.lookup("not-a-token") == {:error, :invalid}
      assert RequestLinks.lookup("") == {:error, :invalid}

      expired = Ash.Seed.update!(link, %{expires_at: DateTime.add(DateTime.utc_now(), -1)})
      assert RequestLinks.lookup(token) == {:error, :invalid}
      assert RequestLinks.status(expired) == :expired

      Ash.Seed.update!(link, %{expires_at: DateTime.add(DateTime.utc_now(), 3600)})
      assert {:ok, _} = RequestLinks.lookup(token)

      revoked = Sites.revoke_request_link!(link, actor: ctx.admin, tenant: ctx.tenant)
      assert RequestLinks.lookup(token) == {:error, :invalid}
      assert RequestLinks.status(revoked) == :revoked

      assert {:error, _} =
               Sites.revoke_request_link(revoked, actor: ctx.admin, tenant: ctx.tenant)
    end

    test "creating and revoking are audited and admin only", ctx do
      link = link!(ctx)
      Sites.revoke_request_link!(link, actor: ctx.admin, tenant: ctx.tenant)

      actions =
        Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false)
        |> Enum.map(& &1.entry["action"])

      assert "request_link.created" in actions
      assert "request_link.revoked" in actions
      assert Cloud.Audit.verify(ctx.tenant.id) == :ok

      # no entry mentions the token or its hash
      refute Enum.any?(
               Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false),
               &(inspect(&1.entry) =~ link.token_hash)
             )

      assert {:error, %Ash.Error.Forbidden{}} =
               Sites.create_request_link(
                 %{site_id: ctx.site.id, msp_contact_id: ctx.contact.id},
                 actor: ctx.approver,
                 tenant: ctx.tenant
               )

      link = link!(ctx)

      assert {:error, %Ash.Error.Forbidden{}} =
               Sites.revoke_request_link(link, actor: ctx.approver, tenant: ctx.tenant)

      assert Sites.list_request_links!(actor: ctx.approver, tenant: ctx.tenant) == []
    end

    test "another tenant cannot see, revoke or make links for this site", ctx do
      other = org!()
      link = link!(ctx)

      assert Sites.list_request_links!(actor: other.admin, tenant: other.tenant) == []
      assert Sites.list_request_links!(actor: other.admin, tenant: ctx.tenant) == []

      assert {:error, _} =
               Sites.revoke_request_link(link, actor: other.admin, tenant: other.tenant)

      assert {:error, _} =
               Sites.create_request_link(
                 %{site_id: ctx.site.id, msp_contact_id: ctx.contact.id},
                 actor: other.admin,
                 tenant: other.tenant
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Sites.create_request_link(
                 %{site_id: ctx.site.id, msp_contact_id: ctx.contact.id},
                 actor: other.admin,
                 tenant: ctx.tenant
               )

      assert RequestLinks.status(Ash.get!(RequestLink, link.id, authorize?: false)) == :active
    end
  end

  describe "requests through a link" do
    test "creates a requested one-off window from the link, whatever else is sent", ctx do
      link = link!(ctx)
      other_site = site!(ctx.tenant, ctx.admin)
      starts_at = local_in(3600)

      assert {:ok, window} =
               RequestLinks.request_window(link, %{
                 "starts_at" => starts_at,
                 "ends_at" => NaiveDateTime.add(starts_at, 7200),
                 "reason" => "INC-42",
                 "site_id" => other_site.id,
                 "kind" => "recurring",
                 "status" => "approved"
               })

      assert window.site_id == ctx.site.id
      assert window.requested_by_id == ctx.contact.id
      assert window.request_link_id == link.id
      assert window.kind == :one_off
      assert window.status == :requested
      assert window.reason == "INC-42"

      # direct use of the action as the link ignores a forged site too
      assert {:ok, forged} =
               Sites.request_window(
                 %{
                   site_id: other_site.id,
                   kind: :one_off,
                   starts_at: starts_at,
                   ends_at: NaiveDateTime.add(starts_at, 600),
                   reason: "x"
                 },
                 actor: link,
                 tenant: ctx.tenant
               )

      assert forged.site_id == ctx.site.id

      used = Ash.get!(RequestLink, link.id, authorize?: false)
      assert used.last_used_at

      [entry | _] =
        Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false)
        |> Enum.filter(&(&1.entry["action"] == "window.requested"))

      assert entry.entry["request_link_id"] == link.id
      assert entry.entry["actor_id"] == nil
    end

    test "validates the times and the reason", ctx do
      link = link!(ctx)

      assert {:error, error} = request(link, %{starts_at: local_in(-3600)})
      assert {:starts_at, "must not be in the past"} in errors(error)

      # a few minutes of slack for a start that is just now
      assert {:ok, _} = request(link, %{starts_at: local_in(-120), ends_at: local_in(1800)})

      assert {:error, error} = request(link, %{ends_at: local_in(3600 + 12 * 3600 + 60)})
      assert {:ends_at, "must be at most 12 hours after the start"} in errors(error)

      assert {:ok, _} = request(link, %{ends_at: local_in(3600 + 12 * 3600)})

      assert {:error, error} = request(link, %{ends_at: local_in(1800)})
      assert {:ends_at, "must be after starts_at"} in errors(error)

      assert {:error, error} = request(link, %{reason: "  "})
      assert Keyword.has_key?(errors(error), :reason)

      assert {:error, error} = request(link, %{starts_at: nil})
      assert Keyword.has_key?(errors(error), :starts_at)
    end

    test "at most 3 pending requests per link", ctx do
      link = link!(ctx)

      [first | _] = for _ <- 1..3, do: elem(request(link), 1)

      assert {:error, error} = request(link)

      assert {:starts_at, "this link already has 3 requests waiting for a decision"} in errors(
               error
             )

      Sites.reject_window!(first, %{note: "not today"}, actor: ctx.approver, tenant: ctx.tenant)
      assert {:ok, _} = request(link)

      # another link has its own count
      assert {:ok, _} = request(link!(ctx))
    end

    test "at most 10 requests per link in 24 hours", ctx do
      link = link!(ctx)

      for _ <- 1..10 do
        {:ok, window} = request(link)
        Sites.reject_window!(window, actor: ctx.approver, tenant: ctx.tenant)
      end

      assert {:error, error} = request(link)

      assert {:starts_at, "this link has made 10 requests in the last 24 hours, try later"} in errors(
               error
             )

      # requests older than a day no longer count
      Cloud.Sites.Window
      |> Ash.Query.filter(request_link_id == ^link.id)
      |> Ash.read!(tenant: ctx.tenant, authorize?: false)
      |> Enum.take(1)
      |> Enum.each(
        &Ash.Seed.update!(&1, %{inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)})
      )

      assert {:ok, _} = request(link)
    end

    test "a revoked or expired link cannot request, even with a stale struct", ctx do
      link = link!(ctx)
      Sites.revoke_request_link!(link, actor: ctx.admin, tenant: ctx.tenant)

      assert {:error, error} = request(link)
      assert {:request_link_id, "this link is not valid"} in errors(error)

      expired = Ash.Seed.update!(link!(ctx), %{expires_at: DateTime.add(DateTime.utc_now(), -1)})
      assert {:error, %Ash.Error.Forbidden{}} = request(expired)
    end

    test "a link reads only its contact's windows for its site", ctx do
      link = link!(ctx)
      {:ok, mine} = request(link)

      other_contact =
        Sites.create_msp_contact!(%{name: "Other", email: "o-#{unique()}@msp.example"},
          actor: ctx.admin,
          tenant: ctx.tenant
        )

      {:ok, _theirs} =
        request(
          Sites.create_request_link!(%{site_id: ctx.site.id, msp_contact_id: other_contact.id},
            actor: ctx.admin,
            tenant: ctx.tenant
          )
        )

      book!(one_off_attrs(ctx.site), ctx.admin, ctx.tenant)

      assert [%{id: id}] = Sites.list_windows!(actor: link, tenant: ctx.tenant)
      assert id == mine.id

      other = org!()
      assert Sites.list_windows!(actor: link, tenant: other.tenant) == []
    end

    test "a request changes no policy until it is approved; reject never publishes", ctx do
      link = link!(ctx)
      {:ok, window} = request(link)
      {:ok, rejected} = request(link)

      assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0

      Sites.reject_window!(rejected, %{note: "use the weekend"},
        actor: ctx.approver,
        tenant: ctx.tenant
      )

      assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0

      # approving needs a passkey step-up bound to this window
      assert {:error, error} =
               Sites.approve_window(window, actor: ctx.approver, tenant: ctx.tenant)

      assert Cloud.Accounts.StepUps.step_up_error?(error)

      wrong =
        verified_step_up!(ctx.approver, :approve_window, window.id, %{id: window.id},
          tenant: ctx.tenant
        ).id

      assert {:error, error} =
               Sites.approve_window(window, %{step_up_id: wrong},
                 actor: ctx.approver,
                 tenant: ctx.tenant
               )

      assert Cloud.Accounts.StepUps.step_up_error?(error)
      assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0

      # a real passkey ceremony with the software authenticator
      {authenticator, _} = passkey!(ctx.approver)

      {_authenticator, step_up} =
        step_up!(ctx.approver, authenticator, :approve_window, window.id, approve_params(window),
          tenant: ctx.tenant
        )

      approved =
        Sites.approve_window!(window, %{step_up_id: step_up.id},
          actor: ctx.approver,
          tenant: ctx.tenant
        )

      assert approved.status == :approved
      assert approved.__metadata__.policy_version.version == 1

      {:ok, latest} =
        Sites.latest_policy_version(ctx.site.id, tenant: ctx.tenant, authorize?: false)

      assert Enum.any?(latest.policy["one_off_windows"], &(&1["id"] == window.id))
    end
  end

  describe "notifications" do
    setup ctx do
      Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Advisories.notifications_topic(ctx.tenant.id))
      :ok
    end

    test "requested, approved and rejected are broadcast after commit", ctx do
      link = link!(ctx)
      site_id = ctx.site.id
      contact_name = ctx.contact.name
      contact_id = ctx.contact.id

      {:ok, window} = request(link)
      window_id = window.id
      starts_at = window.starts_at

      assert_receive {:notification,
                      %{
                        type: :window_requested,
                        site_id: ^site_id,
                        window_id: ^window_id,
                        contact_name: ^contact_name,
                        msp_name: ^contact_name,
                        msp_contact_id: ^contact_id,
                        starts_at: ^starts_at,
                        site_name: "Parramatta clinic",
                        time_zone: "Australia/Sydney"
                      }} = message

      # the notifications dispatcher reads the ids and the msp name from it
      assert {:ok,
              %{
                type: :window_requested,
                site_id: ^site_id,
                window_id: ^window_id,
                msp_contact_id: ^contact_id,
                msp_name: ^contact_name
              }} = Cloud.Notifications.Event.from_message(message)

      approve!(window, ctx.approver)
      approver_email = to_string(ctx.approver.email)

      assert_receive {:notification,
                      %{type: :window_approved, window_id: ^window_id, by: ^approver_email}}

      {:ok, other} = request(link)
      Sites.reject_window!(other, %{note: "no"}, actor: ctx.approver, tenant: ctx.tenant)
      assert_receive {:notification, %{type: :window_rejected, note: "no"}}
    end

    test "a failed action broadcasts nothing", ctx do
      link = link!(ctx)
      assert {:error, _} = request(link, %{starts_at: local_in(-3600)})

      {:ok, window} = request(link)
      assert_receive {:notification, %{type: :window_requested}}

      assert {:error, _} = Sites.approve_window(window, actor: ctx.approver, tenant: ctx.tenant)
      assert {:error, _} = Sites.reject_window(window, actor: ctx.admin, tenant: org!().tenant)
      refute_receive {:notification, _}, 50
    end
  end
end
