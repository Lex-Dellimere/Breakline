defmodule Cloud.Gateways do
  @moduledoc """
  What site gateways report back: events and copies of their audit chain.
  Both are tenant-scoped; writes come only from the gateway channel.
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Cloud.Gateways.Event do
      define :create_event, action: :create
      define :list_events, action: :read
    end

    resource Cloud.Gateways.AuditRecord do
      define :create_audit_record, action: :create
      define :list_audit_records, action: :read
    end
  end
end
