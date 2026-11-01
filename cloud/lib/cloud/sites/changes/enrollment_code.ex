defmodule Cloud.Sites.Changes.EnrollmentCode do
  @moduledoc """
  Gives a new `Cloud.Sites.GatewayEnrollment` its code and expiry, notes the
  fingerprint the site pins now (the box a used code would replace), and
  cancels the site's other pending codes, so a site has at most one code that
  works. Only the code's hash is stored; the raw code is put in the created
  record's `:code` metadata, the one place it is ever handed back.
  """

  use Ash.Resource.Change

  alias Cloud.Sites
  alias Cloud.Sites.GatewayEnrollments

  @impl true
  def change(changeset, _opts, context) do
    {code, code_hash} = GatewayEnrollments.new_code()
    expires_at = DateTime.add(DateTime.utc_now(), GatewayEnrollments.ttl_seconds(), :second)

    changeset
    |> Ash.Changeset.force_change_attributes(code_hash: code_hash, expires_at: expires_at)
    |> Ash.Changeset.before_action(&before(&1, context))
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :code, code)}
    end)
  end

  defp before(changeset, context) do
    site_id = Ash.Changeset.get_attribute(changeset, :site_id)
    tenant = changeset.to_tenant

    case Sites.get_site(site_id, tenant: tenant, authorize?: false, not_found_error?: false) do
      {:ok, %Sites.Site{} = site} ->
        cancel_pending(site_id, tenant, context.actor)

        Ash.Changeset.force_change_attribute(
          changeset,
          :replaced_fingerprint,
          site.gateway_cert_fingerprint
        )

      _ ->
        Ash.Changeset.add_error(changeset, field: :site_id, message: "is not a site")
    end
  end

  # the actor already passed the issue policy; each cancel records itself with that actor
  defp cancel_pending(site_id, tenant, actor) do
    site_id
    |> Sites.pending_gateway_enrollments!(DateTime.utc_now(), tenant: tenant, authorize?: false)
    |> Enum.each(fn enrollment ->
      Sites.cancel_gateway_enrollment!(enrollment,
        actor: actor,
        tenant: tenant,
        authorize?: false,
        context: %{audit_fields: %{reason: "replaced by a new code"}}
      )
    end)
  end
end
