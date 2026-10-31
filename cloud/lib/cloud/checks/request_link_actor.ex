defmodule Cloud.Checks.RequestLinkActor do
  @moduledoc """
  Policy check: the actor is a usable `Cloud.Sites.RequestLink` (neither
  revoked nor expired) acting in its own tenant. Used on
  `Cloud.Sites.Window`'s `:request` action, where
  `Cloud.Sites.Changes.FromRequestLink` sets the site and contact from the
  link and re-checks the link under a row lock.
  """

  use Ash.Policy.SimpleCheck

  alias Cloud.Sites.{RequestLink, RequestLinks}

  @impl true
  def describe(_opts), do: "actor is a usable request link of the tenant"

  @impl true
  def match?(%RequestLink{tenant_id: tenant_id} = link, %{subject: subject}, _opts)
      when is_binary(tenant_id) do
    RequestLinks.usable?(link) and to_tenant(subject) == tenant_id
  end

  def match?(_actor, _context, _opts), do: false

  defp to_tenant(%{to_tenant: tenant}) when is_binary(tenant), do: tenant
  defp to_tenant(_subject), do: nil
end
