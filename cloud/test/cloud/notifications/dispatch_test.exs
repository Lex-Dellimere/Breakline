defmodule Cloud.Notifications.DispatchTest do
  # the dispatcher is its own process and shares the sandbox
  use Cloud.DataCase, async: false
  use Oban.Testing, repo: Cloud.Repo

  import Cloud.Fixtures
  import Cloud.NotificationFixtures

  alias Cloud.Notifications
  alias Cloud.Notifications.{Dispatcher, Event, Worker}

  @moduletag :capture_log

  setup do
    org = org!()
    site = site!(org.tenant, org.admin, %{name: "Parramatta clinic"})
    Map.put(org, :site, site)
  end

  defp start_dispatcher do
    pid = start_supervised!({Dispatcher, rescan_ms: 3_600_000})
    _ = :sys.get_state(pid)
    pid
  end

  defp broadcast(pid, tenant_id, message) do
    Phoenix.PubSub.broadcast(
      Cloud.PubSub,
      Cloud.Advisories.notifications_topic(tenant_id),
      message
    )

    # the dispatcher has handled the broadcast once it answers
    _ = :sys.get_state(pid)
  end

  defp deliveries(tenant) do
    Notifications.list_deliveries!(tenant: tenant, authorize?: false)
  end

  defp notification(ctx, type, extra \\ %{}) do
    {:notification,
     Map.merge(%{type: type, tenant_id: ctx.tenant.id, site_id: ctx.site.id}, extra)}
  end

  test "routes every event type to the channels that receive it", ctx do
    all = channel!(ctx.tenant, ctx.admin, %{kind: :slack, name: "all"})
    email = channel!(ctx.tenant, ctx.admin, %{kind: :email, name: "mail"})

    windows =
      channel!(ctx.tenant, ctx.admin, %{
        kind: :teams,
        name: "windows",
        event_types: [:window_requested, :window_approved, :window_rejected]
      })

    locks =
      channel!(ctx.tenant, ctx.admin, %{
        kind: :sms,
        name: "locks",
        event_types: [:advisory_locked]
      })

    off = channel!(ctx.tenant, ctx.admin, %{kind: :slack, name: "off"})
    Notifications.set_channel_enabled!(off, false, actor: ctx.admin, tenant: ctx.tenant)

    pid = start_dispatcher()

    messages = [
      {:advisory_locked,
       {:advisory,
        %{
          tenant_id: ctx.tenant.id,
          site_id: ctx.site.id,
          advisory_id: Ecto.UUID.generate(),
          status: :locked
        }}},
      {:advisory_pending,
       {:advisory,
        %{
          tenant_id: ctx.tenant.id,
          site_id: ctx.site.id,
          advisory_id: Ecto.UUID.generate(),
          status: :pending
        }}},
      {:window_requested, notification(ctx, :window_requested)},
      {:window_approved, notification(ctx, :window_approved)},
      {:window_rejected, notification(ctx, :window_rejected)},
      {:break_glass_opened, notification(ctx, :break_glass_opened)},
      {:break_glass_revoked, notification(ctx, :break_glass_revoked)}
    ]

    expected = %{
      advisory_locked: [all.id, email.id, locks.id],
      advisory_pending: [all.id, email.id],
      window_requested: [all.id, email.id, windows.id],
      window_approved: [all.id, email.id, windows.id],
      window_rejected: [all.id, email.id, windows.id],
      break_glass_opened: [all.id, email.id],
      break_glass_revoked: [all.id, email.id]
    }

    for {type, message} <- messages do
      broadcast(pid, ctx.tenant.id, message)

      got =
        ctx.tenant
        |> deliveries()
        |> Enum.filter(&(&1.event_type == type))
        |> Enum.map(& &1.channel_id)
        |> Enum.sort()

      assert got == Enum.sort(expected[type]), "#{type}"
    end

    jobs = all_enqueued(worker: Worker)
    assert length(jobs) == expected |> Map.values() |> List.flatten() |> length()
    refute Enum.any?(deliveries(ctx.tenant), &(&1.channel_id == off.id))

    # job args carry ids only, never a target
    args = Jason.encode!(Enum.map(jobs, & &1.args))
    refute args =~ slack_secret()
    refute args =~ teams_sig()
    refute args =~ "+61412345678"
  end

  test "ignores dismissals, unknown messages and other tenants", ctx do
    channel!(ctx.tenant, ctx.admin)
    other = org!()
    pid = start_dispatcher()

    broadcast(
      pid,
      ctx.tenant.id,
      {:advisory, %{tenant_id: ctx.tenant.id, site_id: ctx.site.id, status: :dismissed}}
    )

    broadcast(
      pid,
      ctx.tenant.id,
      {:notification, %{type: :something_new, tenant_id: ctx.tenant.id}}
    )

    broadcast(pid, ctx.tenant.id, {:hello, :world})
    broadcast(pid, ctx.tenant.id, :tick)
    broadcast(pid, ctx.tenant.id, {:notification, %{type: :window_requested}})
    assert deliveries(ctx.tenant) == []

    # an event for another tenant queues nothing here
    broadcast(
      pid,
      other.tenant.id,
      {:notification, %{type: :window_requested, tenant_id: other.tenant.id}}
    )

    assert deliveries(ctx.tenant) == []
    assert Process.alive?(pid)
  end

  test "picks up tenants created after it started", ctx do
    pid = start_dispatcher()
    late = org!()
    slack = channel!(late.tenant, late.admin)

    assert MapSet.member?(Dispatcher.rescan(pid), late.tenant.id)

    broadcast(
      pid,
      late.tenant.id,
      {:notification, %{type: :break_glass_opened, tenant_id: late.tenant.id}}
    )

    assert [%{event_type: :break_glass_opened}] =
             Enum.filter(deliveries(late.tenant), &(&1.channel_id == slack.id))

    assert deliveries(ctx.tenant) == []
  end

  describe "fallback email" do
    test "goes to every admin and approver when the tenant has no email channel", ctx do
      second_admin = user!()
      member!(second_admin, ctx.tenant, :admin)
      outsider = org!()

      {:ok, sent} =
        Notifications.dispatch(%{
          type: :advisory_locked,
          tenant_id: ctx.tenant.id,
          site_id: ctx.site.id
        })

      assert Enum.all?(sent, &(&1.kind == :email and &1.channel_id == nil))

      assert Enum.sort(Enum.map(sent, & &1.recipient_user_id)) ==
               Enum.sort([ctx.admin.id, ctx.approver.id, second_admin.id])

      refute outsider.admin.id in Enum.map(sent, & &1.recipient_user_id)
    end

    test "is sent alongside webhook channels", ctx do
      slack = channel!(ctx.tenant, ctx.admin)
      {:ok, sent} = Notifications.dispatch(%{type: :window_requested, tenant_id: ctx.tenant.id})
      assert length(sent) == 3
      assert Enum.count(sent, &(&1.channel_id == slack.id)) == 1
    end

    test "is not sent once the tenant has an email channel, even a disabled one", ctx do
      email = channel!(ctx.tenant, ctx.admin, %{kind: :email, event_types: [:window_requested]})

      {:ok, []} = Notifications.dispatch(%{type: :advisory_locked, tenant_id: ctx.tenant.id})

      Notifications.set_channel_enabled!(email, false, actor: ctx.admin, tenant: ctx.tenant)
      {:ok, []} = Notifications.dispatch(%{type: :window_requested, tenant_id: ctx.tenant.id})
    end
  end

  test "events keep known string fields only" do
    {:ok, event} =
      Event.from_message(
        {:notification,
         %{
           type: :window_requested,
           tenant_id: "t",
           site_id: "s",
           msp_name: "Acme",
           token: "secret-token",
           magic_link: "https://x/y?token=1",
           window: %{id: 1}
         }}
      )

    assert event == %{type: :window_requested, tenant_id: "t", site_id: "s", msp_name: "Acme"}
    assert Event.from_args(Event.to_args(event)) == event
    assert Event.from_args(%{"type" => "rm_rf", "evil" => "x"}) == %{type: :unknown}
  end
end
