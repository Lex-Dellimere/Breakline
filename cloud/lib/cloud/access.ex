defmodule Cloud.Access do
  @moduledoc """
  One-step access controls for a site, as the demo UI offers them. Each runs
  the underlying resource action as `user`, so the action's policies decide
  whether the user may do it, and each publishes a new policy version.

  - `open_now/3`: an approved one-off window starting now
  - `lock_now/3`: a manual advisory lock with no expiry
  - `unlock/2`: lifts every active manual lock of the site

  Each returns `{:ok, %{policy_version: %Cloud.Sites.PolicyVersion{}, ...}}`.
  """

  require Ash.Query

  alias Cloud.Accounts.User
  alias Cloud.Sites

  @manual "manual"

  @doc """
  Opens the site for `minutes` from now with an approved one-off window.

  The window is written in the site's local time and rounded outward to
  whole minutes: it starts at the current minute and ends at the first whole
  minute at or after now plus `minutes`. Needs an admin or approver.
  """
  @spec open_now(String.t(), pos_integer(), User.t()) :: {:ok, map()} | {:error, term()}
  def open_now(site_id, minutes, %User{} = user) when is_integer(minutes) and minutes > 0 do
    with {:ok, site} <- fetch_site(site_id) do
      {starts_at, ends_at} = local_span(DateTime.utc_now(), minutes, site.time_zone)

      with {:ok, window} <-
             Sites.create_approved_window(
               %{site_id: site.id, kind: :one_off, starts_at: starts_at, ends_at: ends_at},
               actor: user,
               tenant: site.tenant_id
             ) do
        {:ok, %{window: window, policy_version: window.__metadata__.policy_version}}
      end
    end
  end

  @doc """
  Locks the site with a manual advisory lock that holds until `unlock/2`.
  Needs an admin.
  """
  @spec lock_now(String.t(), User.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def lock_now(site_id, %User{} = user, reason) when is_binary(reason) do
    with {:ok, site} <- fetch_site(site_id),
         {:ok, lock} <-
           Sites.create_advisory_lock(
             %{site_id: site.id, reason: reason, source: @manual},
             actor: user,
             tenant: site.tenant_id
           ) do
      {:ok, %{lock: lock, policy_version: lock.__metadata__.policy_version}}
    end
  end

  @doc """
  Lifts every active manual lock of the site and publishes once. Threat-feed
  locks are left alone. Needs an admin. Returns
  `{:error, :no_manual_lock}` when there is nothing to lift.
  """
  @spec unlock(String.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def unlock(site_id, %User{} = user) do
    with {:ok, site} <- fetch_site(site_id) do
      result =
        Cloud.Repo.transaction(fn ->
          with {:ok, [_ | _] = locks} <- manual_locks(site, user),
               {:ok, lifted} <- lift_all(locks, user, site),
               {:ok, version} <-
                 Cloud.Policies.publish_in_transaction(site.id,
                   published_by: user,
                   reason: "manual lock lifted"
                 ) do
            %{locks: lifted, policy_version: version}
          else
            {:ok, []} -> Cloud.Repo.rollback(:no_manual_lock)
            {:error, error} -> Cloud.Repo.rollback(error)
          end
        end)

      with {:ok, %{policy_version: version}} <- result do
        Cloud.Policies.broadcast(version)
        result
      end
    end
  end

  @doc false
  # the local naive span [now floored to the minute, now + minutes ceiled to the minute)
  @spec local_span(DateTime.t(), pos_integer(), String.t()) ::
          {NaiveDateTime.t(), NaiveDateTime.t()}
  def local_span(now, minutes, time_zone) do
    to_local = fn utc ->
      utc |> DateTime.shift_zone!(time_zone, Tz.TimeZoneDatabase) |> DateTime.to_naive()
    end

    starts_at = now |> to_local.() |> floor_minute()
    ends_local = now |> DateTime.add(minutes * 60, :second) |> to_local.()
    floored = floor_minute(ends_local)

    ends_at =
      if NaiveDateTime.compare(floored, ends_local) == :eq,
        do: floored,
        else: NaiveDateTime.add(floored, 60, :second)

    {starts_at, ends_at}
  end

  defp floor_minute(naive), do: %{naive | second: 0, microsecond: {0, 0}}

  defp manual_locks(site, user) do
    Sites.list_advisory_locks(
      actor: user,
      tenant: site.tenant_id,
      query: [filter: [site_id: site.id, source: @manual, lifted_at: [is_nil: true]]]
    )
  end

  defp lift_all(locks, user, site) do
    Enum.reduce_while(locks, {:ok, []}, fn lock, {:ok, acc} ->
      case Sites.lift_advisory_lock(lock,
             actor: user,
             tenant: site.tenant_id,
             context: %{skip_publish?: true}
           ) do
        {:ok, lifted} -> {:cont, {:ok, [lifted | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, lifted} -> {:ok, Enum.reverse(lifted)}
      error -> error
    end
  end

  # trusted lookup of the site's tenant; the actions above still authorise the user
  defp fetch_site(site_id) do
    case Sites.get_site(site_id, authorize?: false, not_found_error?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, site} -> {:ok, site}
      {:error, _} -> {:error, :not_found}
    end
  end
end
