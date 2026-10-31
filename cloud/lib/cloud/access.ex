defmodule Cloud.Access do
  @moduledoc """
  One-step access controls for a site, as the site page offers them. Each
  runs the underlying resource actions as `user`, so the actions' policies
  decide whether the user may do it, and each publishes a new policy version.

  - `open_now/4`: an approved one-off window starting now
  - `lock_now/3`: a manual advisory lock with no expiry
  - `unlock/3`: lifts every active manual lock of the site

  Opening and unlocking need a verified passkey step-up bound to exactly that
  call (threat model T5), see `Cloud.Accounts.StepUps`:

  | call | purpose | subject | params |
  |---|---|---|---|
  | `open_now/4` | `:open_window` | the site id | `%{site_id: id, minutes: m}` |
  | `unlock/3` | `:lift_lock` | the site id | `%{site_id: id, scope: "manual"}` |

  `step_up_params/2` builds these params. Locking closes access and needs no
  step-up.

  Each returns `{:ok, %{policy_version: %Cloud.Sites.PolicyVersion{}, ...}}`.
  """

  require Ash.Query

  alias Cloud.Accounts.{StepUps, User}
  alias Cloud.Sites

  @manual "manual"

  @doc """
  The step-up params for an access call on a site: `{:open, minutes}` or
  `:unlock`. Pass them to `Cloud.Accounts.begin_step_up/5`.
  """
  @spec step_up_params(String.t(), {:open, pos_integer()} | :unlock) :: map()
  def step_up_params(site_id, {:open, minutes}), do: %{site_id: site_id, minutes: minutes}
  def step_up_params(site_id, :unlock), do: %{site_id: site_id, scope: @manual}

  @doc """
  Opens the site for `minutes` from now with an approved one-off window.

  The window is written in the site's local time and rounded outward to
  whole minutes: it starts at the current minute and ends at the first whole
  minute at or after now plus `minutes`. Needs an admin or approver and a
  verified `:open_window` step-up for this site and these minutes.
  """
  @spec open_now(String.t(), pos_integer(), User.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def open_now(site_id, minutes, %User{} = user, step_up_id)
      when is_integer(minutes) and minutes > 0 do
    with {:ok, site} <- fetch_site(site_id),
         {:ok, window} <-
           Sites.open_window_now(
             %{site_id: site.id, minutes: minutes, step_up_id: step_up_id},
             actor: user,
             tenant: site.tenant_id
           ) do
      {:ok, %{window: window, policy_version: window.__metadata__.policy_version}}
    end
  end

  @doc """
  Locks the site with a manual advisory lock that holds until `unlock/3`.
  Needs an admin.
  """
  @spec lock_now(String.t(), User.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def lock_now(site_id, %User{} = user, reason) when is_binary(reason) do
    with {:ok, site} <- fetch_site(site_id),
         {:ok, lock} <-
           Sites.create_advisory_lock(
             %{site_id: site.id, reason: reason, source: @manual},
             actor: user,
             tenant: site.tenant_id,
             context: %{audit_action: "access.lock_now"}
           ) do
      {:ok, %{lock: lock, policy_version: lock.__metadata__.policy_version}}
    end
  end

  @doc """
  Whether the site has an active manual lock that `unlock/3` would lift, as
  `user` can see it.
  """
  @spec manual_lock?(String.t(), User.t()) :: boolean()
  def manual_lock?(site_id, %User{} = user) do
    with {:ok, site} <- fetch_site(site_id),
         {:ok, [_ | _]} <- manual_locks(site, user) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Lifts every active manual lock of the site and publishes once. Threat-feed
  locks are left alone. Needs an admin and a verified `:lift_lock` step-up
  for the site (`step_up_params(site_id, :unlock)`), consumed once for all the
  locks. Returns `{:error, :no_manual_lock}` when there is nothing to lift,
  without spending the step-up.
  """
  @spec unlock(String.t(), User.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def unlock(site_id, %User{} = user, step_up_id) do
    with {:ok, site} <- fetch_site(site_id) do
      result =
        Cloud.Repo.transaction(fn ->
          with {:ok, [_ | _] = locks} <- manual_locks(site, user),
               {:ok, step_up} <- consume(step_up_id, user, site),
               {:ok, lifted} <- lift_all(locks, user, site, step_up),
               {:ok, version} <-
                 Cloud.Policies.publish_in_transaction(site.id,
                   published_by: user,
                   reason: "manual lock lifted"
                 ),
               {:ok, _entry} <-
                 Cloud.Audit.append(
                   site.tenant_id,
                   "access.unlock",
                   %{
                     site_id: site.id,
                     lock_ids: Enum.map(lifted, & &1.id),
                     step_up_id: step_up.id
                   },
                   actor: user
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
  # kept for callers of the old helper; see Cloud.Sites.Changes.OpenNowSpan
  defdelegate local_span(now, minutes, time_zone), to: Cloud.Sites.Changes.OpenNowSpan

  defp consume(step_up_id, user, site) do
    case StepUps.consume(
           step_up_id,
           user,
           :lift_lock,
           site.id,
           step_up_params(site.id, :unlock),
           site.tenant_id
         ) do
      {:ok, step_up} -> {:ok, step_up}
      {:error, reason} -> {:error, Ash.Error.to_error_class(StepUps.error(reason))}
    end
  end

  defp manual_locks(site, user) do
    Sites.list_advisory_locks(
      actor: user,
      tenant: site.tenant_id,
      query: [filter: [site_id: site.id, source: @manual, lifted_at: [is_nil: true]]]
    )
  end

  defp lift_all(locks, user, site, step_up) do
    Enum.reduce_while(locks, {:ok, []}, fn lock, {:ok, acc} ->
      case Sites.lift_advisory_lock(lock,
             actor: user,
             tenant: site.tenant_id,
             context: %{skip_publish?: true, step_up: step_up}
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
