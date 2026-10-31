defmodule Cloud.Accounts do
  @moduledoc """
  Users, tenants and the memberships that link them.
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Cloud.Accounts.Token
    resource Cloud.Accounts.User

    resource Cloud.Accounts.Tenant do
      define :create_tenant, action: :create
      define :list_tenants, action: :read
      define :get_tenant, action: :read, get_by: [:id]
      define :get_tenant_by_slug, action: :read, get_by: [:slug]
      define :update_tenant_settings, action: :update_settings
    end

    resource Cloud.Accounts.Membership do
      define :create_membership, action: :create, args: [:user_id, :tenant_id, :role]
      define :list_memberships, action: :read
      define :membership_for, action: :for_user_in_tenant, args: [:user_id, :tenant_id]
    end
  end
end
