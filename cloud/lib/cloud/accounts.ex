defmodule Cloud.Accounts do
  @moduledoc """
  Users, tenants and the memberships that link them, plus the second factors:
  passkeys (`Cloud.Accounts.Passkey`), TOTP (`Cloud.Accounts.Totp`) and
  step-ups, the passkey assertions bound to one action
  (`Cloud.Accounts.StepUp`, `begin_step_up/5`, `verify_step_up/3`).
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  alias Cloud.Accounts.StepUps

  admin do
    show? true
  end

  resources do
    resource Cloud.Accounts.Token

    resource Cloud.Accounts.User do
      define :record_totp_result, action: :record_totp_result
      define :disable_totp, action: :disable_totp
    end

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

    resource Cloud.Accounts.Passkey do
      define :create_passkey, action: :create
      define :passkeys_for_user, action: :for_user, args: [:user_id]
      define :record_passkey_use, action: :record_use
    end

    resource Cloud.Accounts.StepUp do
      define :create_step_up, action: :begin
      define :lock_step_up, action: :lock, args: [:id]
      define :mark_step_up_verified, action: :mark_verified
      define :mark_step_up_failed, action: :mark_failed
      define :consume_step_up, action: :consume
    end
  end

  @doc """
  Starts a passkey step-up for one action. See `Cloud.Accounts.StepUps.begin/5`.
  """
  defdelegate begin_step_up(user, purpose, subject_id, params, opts \\ []),
    to: StepUps,
    as: :begin

  @doc """
  Verifies the browser's passkey assertion for a step-up. See
  `Cloud.Accounts.StepUps.verify/3`.
  """
  defdelegate verify_step_up(step_up_id, assertion, opts \\ []), to: StepUps, as: :verify
end
