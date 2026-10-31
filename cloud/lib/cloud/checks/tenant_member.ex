defmodule Cloud.Checks.TenantMember do
  @moduledoc """
  Policy check: the actor is a member of the tenant the action runs in, with
  one of the given roles.

      authorize_if {Cloud.Checks.TenantMember, role: :admin}
      authorize_if {Cloud.Checks.TenantMember, role: [:admin, :approver]}

  Without `:role` any membership passes. The tenant is the one the query,
  changeset or action input carries (`tenant:` on the call, or the tenant a
  record was read with). An action without a tenant never passes, so a
  global read of a tenant-scoped resource is forbidden to every actor.

  The membership lookup itself runs with `authorize?: false`: it is the trusted
  step that the authorisation decision is based on.
  """

  use Ash.Policy.SimpleCheck

  alias Cloud.Accounts.User

  @roles [:admin, :approver]

  @impl true
  def describe(opts) do
    case roles(opts) do
      @roles -> "actor is a member of the tenant"
      roles -> "actor is a member of the tenant with role in #{inspect(roles)}"
    end
  end

  @impl true
  def match?(%User{id: user_id}, %{subject: subject}, opts) when is_binary(user_id) do
    case tenant_id(subject) do
      nil ->
        false

      tenant_id ->
        case Cloud.Accounts.membership_for(user_id, tenant_id, authorize?: false) do
          {:ok, membership} -> membership.role in roles(opts)
          {:error, _} -> false
        end
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp roles(opts) do
    case Keyword.get(opts, :role, @roles) do
      role when is_atom(role) -> [role]
      roles when is_list(roles) -> roles
    end
  end

  defp tenant_id(%{to_tenant: tenant}) when is_binary(tenant), do: tenant
  defp tenant_id(_subject), do: nil
end
