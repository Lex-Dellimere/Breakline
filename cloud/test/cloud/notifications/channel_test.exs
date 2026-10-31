defmodule Cloud.Notifications.ChannelTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures
  import Cloud.NotificationFixtures

  alias Cloud.Notifications
  alias Cloud.Notifications.Vault

  setup do
    org!()
  end

  describe "encryption at rest" do
    test "the vault round trips and refuses tampering" do
      ciphertext = Vault.encrypt(slack_url())
      refute ciphertext =~ slack_secret()
      assert {:ok, url} = Vault.decrypt(ciphertext)
      assert url == slack_url()
      assert :error = Vault.decrypt(ciphertext <> "x")
      assert :error = Vault.decrypt("garbage")
      assert :error = Vault.decrypt(nil)
    end

    test "the database never holds the plain webhook url", ctx do
      for kind <- [:slack, :teams] do
        channel = channel!(ctx.tenant, ctx.admin, %{kind: kind})
        plain = target_for(kind)

        %{rows: [[ciphertext, hint]]} =
          Repo.query!(
            "select target_ciphertext, target_hint from notification_channels where id = $1",
            [Ecto.UUID.dump!(channel.id)]
          )

        refute ciphertext =~ plain
        refute ciphertext =~ "hooks.slack.com"
        refute hint =~ slack_secret()
        refute hint =~ teams_sig()

        %{rows: [[dump]]} =
          Repo.query!("select row_to_json(c)::text from notification_channels c where id = $1", [
            Ecto.UUID.dump!(channel.id)
          ])

        refute dump =~ slack_secret()
        refute dump =~ teams_sig()

        assert {:ok, ^plain} = Notifications.target(channel)
      end
    end

    test "the plain target is not on the record and inspect redacts the ciphertext", ctx do
      channel = channel!(ctx.tenant, ctx.admin)
      refute Map.has_key?(channel, :target)
      refute inspect(channel) =~ channel.target_ciphertext
      refute inspect(channel) =~ slack_secret()
    end
  end

  describe "create" do
    test "validates the target for its kind", ctx do
      assert {:error, error} =
               Notifications.create_channel(
                 %{
                   kind: :slack,
                   name: "x",
                   target: "https://hooks.slack.com.evil.example/services/a/b/c"
                 },
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )

      assert Exception.message(error) =~ "Slack"
      refute Exception.message(error) =~ "evil.example"

      assert {:error, _} =
               Notifications.create_channel(%{kind: :sms, name: "x", target: "0412"},
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )
    end

    test "defaults to every event type and records who added it", ctx do
      channel = channel!(ctx.tenant, ctx.admin, %{kind: :email, target: "Ops@Example.com"})
      assert channel.event_types == Cloud.Notifications.Event.types()
      assert channel.enabled
      assert channel.created_by_id == ctx.admin.id
      assert channel.target_hint == "o•••@example.com"
      assert {:ok, "ops@example.com"} = Notifications.target(channel)
    end

    test "adding and removing is audited without the target", ctx do
      channel = channel!(ctx.tenant, ctx.admin, %{name: "Ops Slack"})
      :ok = Notifications.destroy_channel!(channel, actor: ctx.admin, tenant: ctx.tenant)

      entries =
        Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false)
        |> Enum.map(& &1.entry)
        |> Enum.filter(&String.starts_with?(&1["action"], "notification_channel."))

      assert [
               %{
                 "action" => "notification_channel.added",
                 "kind" => "slack",
                 "name" => "Ops Slack"
               } =
                 added,
               %{"action" => "notification_channel.removed", "actor_id" => actor_id}
             ] = entries

      assert actor_id == ctx.admin.id
      assert added["id"] == channel.id
      refute Jason.encode!(entries) =~ slack_secret()
      assert :ok = Cloud.Audit.verify(ctx.tenant.id)
    end
  end

  describe "policies" do
    test "only admins of the tenant see and manage channels", ctx do
      channel = channel!(ctx.tenant, ctx.admin)
      other = org!()

      assert [_] = Notifications.list_channels!(actor: ctx.admin, tenant: ctx.tenant)
      assert [] = Notifications.list_channels!(actor: ctx.approver, tenant: ctx.tenant)
      assert [] = Notifications.list_channels!(actor: other.admin, tenant: ctx.tenant)
      assert [] = Notifications.list_channels!(actor: ctx.admin, tenant: other.tenant)

      for actor <- [ctx.approver, other.admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Notifications.create_channel(
                   %{kind: :slack, name: "x", target: slack_url()},
                   actor: actor,
                   tenant: ctx.tenant
                 )

        assert {:error, _} =
                 Notifications.set_channel_enabled(channel, false,
                   actor: actor,
                   tenant: ctx.tenant
                 )

        assert {:error, _} =
                 Notifications.destroy_channel(channel, actor: actor, tenant: ctx.tenant)
      end

      assert {:ok, %{enabled: false}} =
               Notifications.set_channel_enabled(channel, false,
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )
    end

    test "deliveries are readable by admins only and never writable by actors", ctx do
      channel = channel!(ctx.tenant, ctx.admin)
      {:ok, delivery} = Notifications.send_test(ctx.tenant.id, channel.id, actor: ctx.admin)

      assert [_] = Notifications.list_deliveries!(actor: ctx.admin, tenant: ctx.tenant)
      assert [] = Notifications.list_deliveries!(actor: ctx.approver, tenant: ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               Notifications.record_delivery_result(delivery, %{status: :sent},
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Notifications.enqueue_delivery(%{kind: :slack, event_type: :test},
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )
    end

    test "only an admin can send a test message", ctx do
      channel = channel!(ctx.tenant, ctx.admin)
      assert {:error, _} = Notifications.send_test(ctx.tenant.id, channel.id, actor: ctx.approver)
      other = org!()

      assert {:error, _} =
               Notifications.send_test(other.tenant.id, channel.id, actor: other.admin)
    end
  end
end
