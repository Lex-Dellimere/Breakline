defmodule Cloud.Sites.ValidationsTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Cloud.Sites

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    Map.put(org, :site, site!(tenant, admin))
  end

  defp errors_for(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.fetch!(:errors)
    |> Enum.map(&{&1.field, &1.message})
  end

  defp create_site(ctx, attrs) do
    Sites.create_site(
      Map.merge(%{name: "x", time_zone: "Australia/Sydney"}, attrs),
      actor: ctx.admin,
      tenant: ctx.tenant
    )
  end

  describe "site" do
    test "accepts a valid site and normalises hosts", ctx do
      assert {:ok, site} =
               create_site(ctx, %{
                 tool_ids: ["n_central"],
                 site_hosts: [" RMM.Example.com ", "rmm.example.com", "10.0.0.1", "2001:db8::/32"]
               })

      assert site.site_hosts == ["rmm.example.com", "10.0.0.1", "2001:db8::/32"]
      assert site.mode == :monitor
      assert site.policy_version == 0
    end

    test "rejects an unknown time zone", ctx do
      assert {:error, error} = create_site(ctx, %{time_zone: "Australia/Atlantis"})
      assert [{:time_zone, _}] = errors_for(error)
    end

    test "rejects unknown and repeated tool ids", ctx do
      assert {:error, error} = create_site(ctx, %{tool_ids: ["anydesk", "made_up_rmm"]})
      assert [{:tool_ids, msg}] = errors_for(error)
      assert msg =~ "made_up_rmm"

      assert {:error, error} = create_site(ctx, %{tool_ids: ["anydesk", "anydesk"]})
      assert [{:tool_ids, _}] = errors_for(error)
    end

    test "rejects malformed hosts and too wide cidrs", ctx do
      for bad <- ["not a host", "10.0.0.0/33", "0.0.0.0/0", "10.0.0.0/4", "::/8", "a..b", "x/y/z"] do
        assert {:error, error} = create_site(ctx, %{site_hosts: [bad]}), bad
        assert [{:site_hosts, _}] = errors_for(error)
      end
    end

    test "rejects a bad time zone on update", ctx do
      assert {:error, error} =
               Sites.update_site(ctx.site, %{time_zone: "Nowhere/Place"},
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )

      assert [{:time_zone, _}] = errors_for(error)
    end

    test "gateway fingerprint must be lowercase sha256 hex", ctx do
      assert {:error, _} =
               Sites.assign_gateway(ctx.site, String.duplicate("A", 64),
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )

      fp = :crypto.hash(:sha256, "cert") |> Base.encode16(case: :lower)

      assert {:ok, %{gateway_cert_fingerprint: ^fp}} =
               Sites.assign_gateway(ctx.site, fp, actor: ctx.admin, tenant: ctx.tenant)

      assert {:ok, %{id: id}} = Sites.get_site_by_gateway_fingerprint(fp, authorize?: false)
      assert id == ctx.site.id
    end
  end

  describe "window shape" do
    defp request(ctx, attrs) do
      Sites.request_window(attrs, actor: ctx.admin, tenant: ctx.tenant)
    end

    test "accepts valid recurring and one-off windows", ctx do
      assert {:ok, %{status: :requested}} = request(ctx, recurring_attrs(ctx.site))
      assert {:ok, %{status: :requested}} = request(ctx, one_off_attrs(ctx.site))
    end

    test "recurring windows follow the policy rules", ctx do
      bad = [
        {%{days: []}, :days},
        {%{days: [0, 1]}, :days},
        {%{days: [8]}, :days},
        {%{days: [1, 1]}, :days},
        {%{starts: ~T[22:00:30]}, :starts},
        {%{ends: ~T[22:00:00]}, :ends},
        {%{ends: nil}, :ends},
        {%{starts_at: ~N[2030-01-01 09:00:00]}, :starts_at}
      ]

      for {attrs, field} <- bad do
        assert {:error, error} = request(ctx, recurring_attrs(ctx.site, attrs)), inspect(attrs)
        assert field in Enum.map(errors_for(error), &elem(&1, 0)), inspect(attrs)
      end
    end

    test "one-off windows follow the policy rules", ctx do
      bad = [
        {%{ends_at: ~N[2030-01-01 09:00:00]}, :ends_at},
        {%{ends_at: ~N[2030-01-01 08:00:00]}, :ends_at},
        {%{starts_at: ~N[2030-01-01 09:00:15]}, :starts_at},
        {%{starts_at: nil}, :starts_at},
        {%{days: [1]}, :days},
        {%{starts: ~T[10:00:00]}, :starts}
      ]

      for {attrs, field} <- bad do
        assert {:error, error} = request(ctx, one_off_attrs(ctx.site, attrs)), inspect(attrs)
        assert field in Enum.map(errors_for(error), &elem(&1, 0)), inspect(attrs)
      end
    end

    test "only a requested window can be approved", ctx do
      window =
        Sites.request_window!(recurring_attrs(ctx.site), actor: ctx.admin, tenant: ctx.tenant)

      window = Sites.approve_window!(window, actor: ctx.approver, tenant: ctx.tenant)
      assert window.status == :approved
      assert window.approved_by_id == ctx.approver.id
      assert window.approved_at

      assert {:error, _} = Sites.approve_window(window, actor: ctx.approver, tenant: ctx.tenant)
      assert {:error, _} = Sites.reject_window(window, actor: ctx.approver, tenant: ctx.tenant)
    end

    test "a break-glass must end in the future", ctx do
      assert {:error, _} =
               Sites.create_break_glass(
                 %{site_id: ctx.site.id, until: DateTime.add(DateTime.utc_now(), -60)},
                 actor: ctx.approver,
                 tenant: ctx.tenant
               )
    end
  end
end
