defmodule Cloud.PoliciesConcurrencyTest do
  # real concurrent transactions: the sandbox would serialise them on one connection,
  # so this test commits for real and cleans up after itself
  use ExUnit.Case, async: false

  import Cloud.Fixtures

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Cloud.Repo, sandbox: false)
    Sandbox.mode(Cloud.Repo, {:shared, self()})

    %{tenant: tenant, admin: admin, approver: approver} = org!()
    site = site!(tenant, admin)

    on_exit(fn ->
      :ok = Sandbox.checkout(Cloud.Repo, sandbox: false)
      # memberships, sites and everything under them cascade from the tenant
      Cloud.Repo.query!("delete from tenants where id = $1", [Ecto.UUID.dump!(tenant.id)])

      Cloud.Repo.query!("delete from users where id = any($1)", [
        Enum.map([admin.id, approver.id], &Ecto.UUID.dump!/1)
      ])
    end)

    %{site: site}
  end

  test "concurrent publishes for one site get distinct consecutive versions", %{site: site} do
    n = 12

    versions =
      1..n
      |> Task.async_stream(
        fn i -> Cloud.Policies.publish(site.id, reason: "concurrent #{i}") end,
        max_concurrency: n,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, version}} -> version.version end)

    assert Enum.sort(versions) == Enum.to_list(1..n)

    stored =
      Cloud.Sites.list_policy_versions!(tenant: site.tenant_id, authorize?: false)
      |> Enum.map(&{&1.version, &1.policy["version"]})
      |> Enum.sort()

    assert stored == Enum.map(1..n, &{&1, &1})
    assert Cloud.Sites.get_site!(site.id, authorize?: false).policy_version == n
  end
end
