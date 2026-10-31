defimpl Ash.ToTenant, for: Cloud.Accounts.Tenant do
  # tenant-scoped resources use attribute multitenancy on tenant_id, so a tenant
  # struct passed as `tenant:` resolves to its id
  def to_tenant(%{id: id}, _resource), do: id
end
