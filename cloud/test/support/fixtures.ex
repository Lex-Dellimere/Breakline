defmodule Cloud.Fixtures do
  @moduledoc """
  Test data builders. Identity fields get globally unique values so async
  tests never collide.
  """

  alias Cloud.Accounts
  alias Cloud.Sites

  def unique, do: System.unique_integer([:positive])

  def user!(attrs \\ %{}) do
    Ash.Seed.seed!(
      Cloud.Accounts.User,
      Map.merge(
        %{email: "user-#{unique()}@example.test", hashed_password: "not-a-real-hash"},
        attrs
      )
    )
  end

  def tenant!(attrs \\ %{}) do
    n = unique()

    Accounts.create_tenant!(Map.merge(%{name: "Tenant #{n}", slug: "t-#{n}"}, attrs),
      authorize?: false
    )
  end

  def member!(user, tenant, role) do
    Accounts.create_membership!(user.id, tenant.id, role, authorize?: false)
  end

  @doc "A tenant with an admin and an approver."
  def org! do
    tenant = tenant!()
    admin = user!()
    approver = user!()
    member!(admin, tenant, :admin)
    member!(approver, tenant, :approver)
    %{tenant: tenant, admin: admin, approver: approver}
  end

  def site!(tenant, admin, attrs \\ %{}) do
    Sites.create_site!(
      Map.merge(
        %{
          name: "Site #{unique()}",
          time_zone: "Australia/Sydney",
          mode: :enforce,
          tool_ids: ["anydesk", "screenconnect"],
          site_hosts: ["rmm.example.com.au", "203.0.113.0/24"]
        },
        attrs
      ),
      actor: admin,
      tenant: tenant
    )
  end

  def recurring_attrs(site, attrs \\ %{}) do
    Map.merge(
      %{
        site_id: site.id,
        kind: :recurring,
        days: [1, 2, 3, 4, 5],
        starts: ~T[22:00:00],
        ends: ~T[02:00:00]
      },
      attrs
    )
  end

  def one_off_attrs(site, attrs \\ %{}) do
    Map.merge(
      %{
        site_id: site.id,
        kind: :one_off,
        starts_at: ~N[2030-01-01 09:00:00],
        ends_at: ~N[2030-01-01 11:00:00]
      },
      attrs
    )
  end
end
