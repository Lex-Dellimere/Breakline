defmodule Cloud.Advisories.Responder do
  @moduledoc """
  Acts on one new advisory: for every site, in every tenant, whose tools
  intersect the advisory's `tool_ids`, records a `Cloud.Advisories.SiteAdvisory`.

  - KEV, tenant `advisory_mode: :auto_lock`: `:locked` (the lock is created
    and published by the `:record` action).
  - KEV, tenant `advisory_mode: :ask`, and every ACSC match: `:pending`.

  It is idempotent: a site that already has a site advisory for this
  advisory is skipped, and the `(site, advisory)` identity stops a second
  one even under a race. An ACSC advisory also skips sites that already
  have a site advisory for a KEV advisory with one of its CVEs, so the same
  vulnerability is not raised twice. Afterwards the advisory is marked
  processed.

  This is a trusted path (`authorize?: false`).
  """

  require Ash.Query
  require Logger

  alias Cloud.Accounts.Tenant
  alias Cloud.Advisories
  alias Cloud.Advisories.{Advisory, SiteAdvisory}
  alias Cloud.Sites.Site

  @trusted [authorize?: false]

  @doc """
  Acts on `advisory` and returns `{:ok, [%{site_id:, advisory_id:, status:}]}`
  for the site advisories it created.
  """
  @spec act(Advisory.t()) :: {:ok, [map()]} | {:error, term()}
  def act(%Advisory{tool_ids: []} = advisory), do: done(advisory, [])

  def act(%Advisory{} = advisory) do
    sites = sites_using(advisory.tool_ids)
    modes = tenant_modes(sites)
    kev_ids = related_kev_ids(advisory)

    sites
    |> Enum.reject(&already_raised?(&1, advisory, kev_ids))
    |> Enum.reduce_while({:ok, []}, fn site, {:ok, acc} ->
      status = status(advisory, Map.get(modes, site.tenant_id))

      case Advisories.record_site_advisory(
             %{site_id: site.id, advisory_id: advisory.id, status: status},
             [tenant: site.tenant_id] ++ @trusted
           ) do
        {:ok, record} ->
          {:cont,
           {:ok, [%{site_id: site.id, advisory_id: advisory.id, status: record.status} | acc]}}

        {:error, error} ->
          if identity_conflict?(error),
            do: {:cont, {:ok, acc}},
            else: {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acted} -> done(advisory, Enum.reverse(acted))
      error -> error
    end
  end

  defp status(%Advisory{source: :kev}, :auto_lock), do: :locked
  defp status(_advisory, _mode), do: :pending

  defp done(advisory, acted) do
    with {:ok, _} <- Advisories.mark_advisory_processed(advisory, @trusted), do: {:ok, acted}
  end

  defp sites_using(tool_ids) do
    Site
    |> Ash.Query.filter(fragment("? && ?::text[]", tool_ids, ^tool_ids))
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(@trusted)
  end

  defp tenant_modes([]), do: %{}

  defp tenant_modes(sites) do
    ids = sites |> Enum.map(& &1.tenant_id) |> Enum.uniq()

    Tenant
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(@trusted)
    |> Map.new(&{&1.id, &1.advisory_mode})
  end

  # kev advisories for the cves of an acsc item, which may already have acted
  defp related_kev_ids(%Advisory{source: :acsc, cves: [_ | _] = cves}) do
    Advisory
    |> Ash.Query.filter(source == :kev and external_id in ^cves)
    |> Ash.read!(@trusted)
    |> Enum.map(& &1.id)
  end

  defp related_kev_ids(_advisory), do: []

  defp already_raised?(site, advisory, kev_ids) do
    ids = [advisory.id | kev_ids]

    SiteAdvisory
    |> Ash.Query.filter(site_id == ^site.id and advisory_id in ^ids)
    |> Ash.Query.set_tenant(site.tenant_id)
    |> Ash.exists?(@trusted)
  end

  defp identity_conflict?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &identity_conflict?/1)

  defp identity_conflict?(%Ash.Error.Changes.InvalidAttribute{private_vars: vars})
       when is_list(vars),
       do: Keyword.get(vars, :constraint_type) == :unique

  defp identity_conflict?(_error), do: false
end
