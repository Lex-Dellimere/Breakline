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

  @doc """
  The tenants the user is a member of (every membership is an admin or an
  approver), by name.
  """
  @spec tenants(User.t()) :: [Accounts.Tenant.t()]
  def tenants(%User{} = user) do
    Accounts.list_memberships!(actor: user, query: [filter: [user_id: user.id], load: [:tenant]])
    |> Enum.map(& &1.tenant)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  @doc "The tenant's sites the user can see, by name."
  @spec tenant_sites(User.t(), String.t()) :: [Sites.Site.t()]
  def tenant_sites(%User{} = user, tenant_id) do
    Sites.list_sites!(actor: user, tenant: tenant_id)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
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

  @doc """
  The user's role in a tenant (`:admin`, `:approver`) or nil. Only decides
  what the page offers; every action is still authorised by its resource.
  """
  @spec role(User.t(), String.t()) :: atom() | nil
  def role(%User{} = user, tenant_id) do
    case Accounts.membership_for(user.id, tenant_id, authorize?: false) do
      {:ok, %{role: role}} -> role
      _ -> nil
    end
  end

  @doc """
  The site's active break-glass, if any, with `approved_by` loaded (a
  trusted load of the opener's email; users cannot read other users).
  """
  @spec current_break_glass(User.t(), Sites.Site.t()) :: Sites.BreakGlass.t() | nil
  def current_break_glass(%User{} = user, site) do
    now = DateTime.utc_now()

    Sites.list_break_glasses!(
      actor: user,
      tenant: site.tenant_id,
      query: [
        filter: [site_id: site.id, revoked_at: [is_nil: true], until: [greater_than: now]],
        sort: [inserted_at: :desc, id: :desc],
        limit: 1
      ]
    )
    |> case do
      [break_glass] -> Ash.load!(break_glass, :approved_by, authorize?: false)
      [] -> nil
    end
  end

  @doc "The site's MSP request links, newest first, with their contacts (admins only)."
  @spec request_links(User.t(), Sites.Site.t()) :: [Sites.RequestLink.t()]
  def request_links(%User{} = user, site) do
    Sites.list_request_links!(
      actor: user,
      tenant: site.tenant_id,
      query: [filter: [site_id: site.id], sort: [inserted_at: :desc], load: [:msp_contact]]
    )
  end

  @doc "The tenant's MSP contacts, by name."
  @spec msp_contacts(User.t(), String.t()) :: [Sites.MspContact.t()]
  def msp_contacts(%User{} = user, tenant_id) do
    Sites.list_msp_contacts!(actor: user, tenant: tenant_id, query: [sort: [name: :asc]])
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
