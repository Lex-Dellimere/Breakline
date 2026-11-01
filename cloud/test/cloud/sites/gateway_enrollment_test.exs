defmodule Cloud.Sites.GatewayEnrollmentTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Cloud.Sites
  alias Cloud.Sites.GatewayEnrollments

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    Map.put(org, :site, site!(tenant, admin))
  end

  defp actions(tenant) do
    Cloud.Audit.audit_chain!(tenant: tenant.id, authorize?: false)
    |> Enum.map(& &1.entry)
  end

  describe "codes" do
    test "are 160 bits of grouped base32, and only their hash is kept" do
      {code, hash} = GatewayEnrollments.new_code()
      assert code =~ ~r/^[A-Z2-7]{4}(-[A-Z2-7]{4}){7}$/
      assert hash =~ ~r/^[0-9a-f]{64}$/
      assert GatewayEnrollments.hash_code(code) == hash
      {other, _} = GatewayEnrollments.new_code()
      assert other != code
    end

    test "are read back ignoring case, spaces and dashes" do
      {code, hash} = GatewayEnrollments.new_code()
      assert GatewayEnrollments.hash_code(String.downcase(code)) == hash
      assert GatewayEnrollments.hash_code(String.replace(code, "-", " ")) == hash
      assert GatewayEnrollments.hash_code(String.replace(code, "-", "")) == hash
    end

    test "a malformed code still hashes, to something no code has" do
      for bad <- ["", "nope", String.duplicate("A", 31), String.duplicate("1", 32)] do
        assert GatewayEnrollments.hash_code(bad) =~ ~r/^[0-9a-f]{64}$/
      end
    end
  end

  describe "issue" do
    test "needs an :enroll_gateway step-up for the site and records it", ctx do
      assert {:error, error} = GatewayEnrollments.issue(ctx.site, ctx.admin, nil)
      assert Cloud.Accounts.StepUps.step_up_error?(error)

      other = site!(ctx.tenant, ctx.admin)

      wrong =
        verified_step_up!(ctx.admin, :enroll_gateway, other.id, %{site_id: other.id},
          tenant: ctx.tenant
        )

      assert {:error, _} = GatewayEnrollments.issue(ctx.site, ctx.admin, wrong.id)

      {code, enrollment} = enrollment!(ctx.site, ctx.admin)
      assert GatewayEnrollments.hash_code(code) == enrollment.code_hash
      assert_in_delta DateTime.diff(enrollment.expires_at, DateTime.utc_now()), 1800, 5
      assert enrollment.created_by_id == ctx.admin.id

      assert %{"action" => "gateway_enrollment.issued", "replaced_fingerprint" => nil} =
               List.last(actions(ctx.tenant))

      # the audit never sees the code or its hash
      refute inspect(actions(ctx.tenant)) =~ code
      refute inspect(actions(ctx.tenant)) =~ enrollment.code_hash
    end

    test "approvers cannot issue codes", ctx do
      step_up =
        verified_step_up!(ctx.approver, :enroll_gateway, ctx.site.id, %{site_id: ctx.site.id},
          tenant: ctx.tenant
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               GatewayEnrollments.issue(ctx.site, ctx.approver, step_up.id)
    end

    test "a new code cancels the site's pending one", ctx do
      {first_code, first} = enrollment!(ctx.site, ctx.admin)
      {_code, second} = enrollment!(ctx.site, ctx.admin)

      assert [pending] =
               Sites.pending_gateway_enrollments!(ctx.site.id, DateTime.utc_now(),
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )

      assert pending.id == second.id

      assert %{"action" => "gateway_enrollment.cancelled", "id" => id} =
               Enum.find(actions(ctx.tenant), &(&1["action"] == "gateway_enrollment.cancelled"))

      assert id == first.id
      assert {:error, :invalid} = GatewayEnrollments.enroll(first_code, "cert", nil)
    end

    test "notes the fingerprint it would replace", ctx do
      {site, _der} = gateway!(ctx.site)
      {_code, enrollment} = enrollment!(site, ctx.admin)
      assert enrollment.replaced_fingerprint == site.gateway_cert_fingerprint
    end
  end

  describe "enroll" do
    test "pins the certificate's fingerprint, once", ctx do
      {code, _} = enrollment!(ctx.site, ctx.admin)
      der = :crypto.strong_rand_bytes(100)

      assert {:ok, %{site: site, replaced_fingerprint: nil}} =
               GatewayEnrollments.enroll(code, der, "192.0.2.7")

      assert site.gateway_cert_fingerprint == Cloud.Gateways.cert_fingerprint(der)

      assert %{
               "action" => "gateway_enrollment.used",
               "actor_id" => nil,
               "gateway_cert_fingerprint" => fp,
               "remote_ip" => "192.0.2.7"
             } = Enum.find(actions(ctx.tenant), &(&1["action"] == "gateway_enrollment.used"))

      assert fp == site.gateway_cert_fingerprint
      assert {:error, :invalid} = GatewayEnrollments.enroll(code, der, nil)
      assert :ok = Cloud.Audit.verify(ctx.tenant.id)
    end

    test "publishes a site's first policy with its first box, and only then", ctx do
      assert ctx.site.policy_version == 0
      {code, _} = enrollment!(ctx.site, ctx.admin)
      :ok = Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(ctx.site.id))

      assert {:ok, %{site: site, published: %{version: 1, reason: "first gateway enrolled"}}} =
               GatewayEnrollments.enroll(code, :crypto.strong_rand_bytes(100), nil)

      assert site.policy_version == 1
      assert_receive {:policy_published, _, 1}

      # a replacement box joins to whatever is published, nothing new
      {again, _} = enrollment!(site, ctx.admin)

      assert {:ok, %{site: %{policy_version: 1}, published: nil}} =
               GatewayEnrollments.enroll(again, :crypto.strong_rand_bytes(100), nil)

      assert :ok = Cloud.Audit.verify(ctx.tenant.id)
    end

    test "refuses a certificate another site pins", ctx do
      {other, der} = gateway!(site!(ctx.tenant, ctx.admin))
      {code, _} = enrollment!(ctx.site, ctx.admin)
      assert {:error, :certificate_in_use} = GatewayEnrollments.enroll(code, der, nil)

      # nothing changed, and the code still works for another certificate
      assert Sites.get_site!(other.id, authorize?: false).gateway_cert_fingerprint ==
               other.gateway_cert_fingerprint

      assert {:ok, _} = GatewayEnrollments.enroll(code, "another", nil)
    end

    test "refuses cancelled and expired codes", ctx do
      {code, enrollment} = enrollment!(ctx.site, ctx.admin)

      Sites.cancel_gateway_enrollment!(enrollment, actor: ctx.admin, tenant: ctx.tenant)
      assert {:error, :invalid} = GatewayEnrollments.enroll(code, "cert", nil)

      assert %{"action" => "gateway_enrollment.cancelled", "actor_id" => actor_id} =
               List.last(actions(ctx.tenant))

      assert actor_id == ctx.admin.id

      {code, enrollment} = enrollment!(ctx.site, ctx.admin)
      expire_enrollment!(enrollment)
      assert {:error, :invalid} = GatewayEnrollments.enroll(code, "cert", nil)
      assert {:error, :invalid} = GatewayEnrollments.enroll("not a code", "cert", nil)
    end

    test "approvers cannot cancel or list codes", ctx do
      {_code, enrollment} = enrollment!(ctx.site, ctx.admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Sites.cancel_gateway_enrollment(enrollment,
                 actor: ctx.approver,
                 tenant: ctx.tenant
               )

      assert [] = Sites.list_gateway_enrollments!(actor: ctx.approver, tenant: ctx.tenant)
    end
  end
end
