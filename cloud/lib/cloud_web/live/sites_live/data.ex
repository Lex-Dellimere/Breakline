defmodule CloudWeb.SitesLive.Data do
  @moduledoc """
  Reads for the sites pages, always as the signed-in user: the user's tenants
  come from their memberships, and every site, window and event is read with
  `actor:` and `tenant:` so the resource policies decide what is visible.
  """

  alias Cloud.{Accounts, Gateways, Sites}
  alias Cloud.Accounts.User

  @doc "The ids of the tenants the user is a member of."
  @spec tenant_ids(User.t()) :: [String.t()]
  def tenant_ids(%User{} = user) do
    Accounts.list_memberships!(actor: user, query: [filter: [user_id: user.id]])
    |> Enum.map(& &1.tenant_id)
    |> Enum.uniq()
  end

  @doc "Every site the user can see, by name."
  @spec list_sites(User.t()) :: [Sites.Site.t()]
  def list_sites(%User{} = user) do
    user
    |> tenant_ids()
    |> Enum.flat_map(&Sites.list_sites!(actor: user, tenant: &1))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc """
  One site, when the user is a member of its tenant. Returns `{:ok, site}` or
  `{:error, :not_found}`, also for an id that is not a uuid.
  """
  @spec get_site(User.t(), String.t()) :: {:ok, Sites.Site.t()} | {:error, :not_found}
  def get_site(%User{} = user, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         # trusted lookup of the site's tenant only; the read below is authorised
         {:ok, %{tenant_id: tenant_id}} <-
           Sites.get_site(id, authorize?: false, not_found_error?: false),
         true <- tenant_id in tenant_ids(user),
         {:ok, %{} = site} <-
           Sites.get_site(id, actor: user, tenant: tenant_id, not_found_error?: false) do
      {:ok, site}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The site's windows."
  @spec windows(User.t(), Sites.Site.t()) :: [Sites.Window.t()]
  def windows(%User{} = user, site) do
    Sites.list_windows!(actor: user, tenant: site.tenant_id, query: [filter: [site_id: site.id]])
  end

  @doc "The site's newest gateway events, newest first."
  @spec recent_events(User.t(), Sites.Site.t(), pos_integer()) :: [Gateways.Event.t()]
  def recent_events(%User{} = user, site, limit) do
    Gateways.list_events!(
      actor: user,
      tenant: site.tenant_id,
      query: [filter: [site_id: site.id], sort: [at: :desc, inserted_at: :desc], limit: limit]
    )
  end
end
