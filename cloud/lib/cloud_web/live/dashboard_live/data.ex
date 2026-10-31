defmodule CloudWeb.DashboardLive.Data do
  @moduledoc """
  Reads for the dashboard, always as the signed-in user with the tenant, so
  the resource policies decide what is visible: the tenant's sites with
  their windows, active break-glass and latest published policy, and the
  counts of pending requests and advisories.

  `upcoming_windows/3` is pure: it expands a published policy's windows with
  `Breakline.Schedule.windows_between/3`.
  """

  alias Breakline.{Policy, Schedule}
  alias Cloud.{Advisories, Sites}
  alias Cloud.Accounts.User
  alias CloudWeb.SitesLive.Data, as: SitesData

  @upcoming_days 7

  @typedoc "One window occurrence on the dashboard."
  @type occurrence :: %{
          id: String.t(),
          kind: :recurring | :one_off,
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          active?: boolean()
        }

  @doc "How many days ahead the dashboard lists windows."
  def upcoming_days, do: @upcoming_days

  @doc """
  Everything the dashboard shows for one tenant at `now`:

    * `:sites`: one map per site, by name, with `:site`, `:windows` (its
      windows, for the state reason), `:break_glass` (the active one or
      nil), `:upcoming` (`upcoming_windows/3` of its latest published
      policy) and `:locked_by_advisory?` (the published policy has an
      advisory lock active now, which wins over any window)
    * `:pending_requests` and `:pending_advisories`: counts
  """
  @spec overview(User.t(), String.t(), DateTime.t()) :: map()
  def overview(%User{} = user, tenant_id, now) do
    opts = [actor: user, tenant: tenant_id]
    sites = SitesData.tenant_sites(user, tenant_id)
    site_ids = Enum.map(sites, & &1.id)

    windows =
      Sites.list_windows!(Keyword.put(opts, :query, filter: [site_id: [in: site_ids]]))
      |> Enum.group_by(& &1.site_id)

    break_glasses =
      Sites.list_break_glasses!(
        Keyword.put(opts, :query,
          filter: [revoked_at: [is_nil: true], until: [greater_than: now]],
          sort: [inserted_at: :desc, id: :desc]
        )
      )
      |> Enum.group_by(& &1.site_id)
      |> Map.new(fn {site_id, [newest | _]} -> {site_id, newest} end)

    %{
      sites:
        Enum.map(sites, fn site ->
          policy = latest_policy(site, opts)

          %{
            site: site,
            windows: Map.get(windows, site.id, []),
            break_glass: Map.get(break_glasses, site.id),
            upcoming: upcoming_windows(policy, now),
            locked_by_advisory?: locked_by_advisory?(policy, now)
          }
        end),
      pending_requests:
        Sites.list_windows!(
          Keyword.put(opts, :query,
            filter: [status: :requested, requested_by_id: [is_nil: false]],
            select: [:id]
          )
        )
        |> length(),
      pending_advisories:
        Advisories.list_site_advisories!(
          Keyword.put(opts, :query, filter: [status: :pending], select: [:id])
        )
        |> length()
    }
  end

  defp latest_policy(site, opts) do
    case Sites.latest_policy_version(site.id, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, %{policy: map}} ->
        case Policy.from_map(map) do
          {:ok, policy} -> policy
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  The window occurrences of a published policy from `now` to `days` days
  later, oldest first, including one that is already running (`active?`).
  Times are UTC; daylight saving is resolved by `Breakline.Schedule`, so an
  occurrence across a change keeps the local times the policy says (or the
  transition instant for a local time that does not exist). Returns `[]` for
  no policy.
  """
  @spec upcoming_windows(Policy.t() | nil, DateTime.t(), pos_integer()) :: [occurrence()]
  def upcoming_windows(policy, now, days \\ @upcoming_days)

  def upcoming_windows(nil, _now, _days), do: []

  def upcoming_windows(%Policy{} = policy, now, days) do
    one_off_ids = MapSet.new(policy.one_off_windows, & &1.id)

    policy
    |> Schedule.windows_between(now, DateTime.add(now, days * 86_400, :second))
    |> Enum.map(fn {starts_at, ends_at, id} ->
      %{
        id: id,
        kind: if(MapSet.member?(one_off_ids, id), do: :one_off, else: :recurring),
        starts_at: starts_at,
        ends_at: ends_at,
        active?: DateTime.compare(starts_at, now) != :gt
      }
    end)
  end

  defp locked_by_advisory?(nil, _now), do: false

  defp locked_by_advisory?(%Policy{advisory_locks: locks}, now) do
    Enum.any?(locks, fn lock ->
      is_nil(lock.expires_at) or DateTime.compare(lock.expires_at, now) == :gt
    end)
  end
end
