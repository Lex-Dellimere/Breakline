defmodule Cloud.Sites do
  @moduledoc """
  Sites and everything that decides whether their RMM channel is open:
  windows, advisory locks, break-glass, MSP contacts and the published policy
  versions.

  All resources are tenant-scoped (attribute multitenancy on `tenant_id`).
  Pass `actor:` and `tenant:` (a `Cloud.Accounts.Tenant` or its id), or a
  `Cloud.Accounts.Scope` as `scope:`. Functions marked trusted in their
  action description are for server code running with `authorize?: false`.
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Cloud.Sites.Site do
      define :create_site, action: :create
      define :list_sites, action: :read
      define :get_site, action: :read, get_by: [:id]
      define :update_site, action: :update
      define :assign_gateway, action: :assign_gateway, args: [:gateway_cert_fingerprint]
      define :lock_site_for_publish, action: :lock_for_publish, args: [:id]
      define :bump_policy_version, action: :bump_policy_version

      define :get_site_by_gateway_fingerprint,
        action: :by_gateway_fingerprint,
        args: [:gateway_cert_fingerprint]

      define :record_heartbeat, action: :record_heartbeat, args: [:gateway_status]

      define :anchor_audit,
        action: :anchor_audit,
        args: [:gateway_audit_chain_id, :gateway_audit_head]
    end

    resource Cloud.Sites.Window do
      define :request_window, action: :request
      define :create_approved_window, action: :create_approved
      define :list_windows, action: :read
      define :get_window, action: :read, get_by: [:id]
      define :approve_window, action: :approve
      define :reject_window, action: :reject
      define :cancel_window, action: :cancel
      define :policy_windows, action: :in_policy, args: [:site_id, :cutoff]
    end

    resource Cloud.Sites.AdvisoryLock do
      define :create_advisory_lock, action: :create
      define :list_advisory_locks, action: :read
      define :lift_advisory_lock, action: :lift
      define :active_advisory_locks, action: :active, args: [:site_id, :now]
    end

    resource Cloud.Sites.BreakGlass do
      define :create_break_glass, action: :create
      define :list_break_glasses, action: :read
      define :revoke_break_glass, action: :revoke
      define :current_break_glass, action: :current, args: [:site_id, :now]
    end

    resource Cloud.Sites.MspContact do
      define :create_msp_contact, action: :create
      define :list_msp_contacts, action: :read
      define :update_msp_contact, action: :update
      define :destroy_msp_contact, action: :destroy
    end

    resource Cloud.Sites.PolicyVersion do
      define :list_policy_versions, action: :read
      define :latest_policy_version, action: :latest, args: [:site_id]
      define :create_policy_version, action: :create
    end
  end
end
