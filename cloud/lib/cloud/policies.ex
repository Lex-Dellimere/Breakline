defmodule Cloud.Policies do
  @moduledoc """
  Builds, stores and signs site policies.

  `publish/2` turns a site's current state (approved windows, active advisory
  locks, the current break-glass) into a `Breakline.Policy` with the next
  version and stores it as a `Cloud.Sites.PolicyVersion`. `command_for/2`
  signs the latest stored version as a fresh `Breakline.Command` for delivery.

  These are trusted server paths: they read and write with `authorize?: false`
  and must only be called after the caller has authorised the change that
  led to them. Resource actions that affect the policy publish through
  `Cloud.Sites.Changes.Publish`, which runs the action's own policies first.

  After a publish commits, `{:policy_published, site_id, version}` is
  broadcast on the `Cloud.PubSub` topic `topic(site_id)`.
  """

  require Ash.Query

  alias Breakline.Policy
  alias Cloud.Accounts.User
  alias Cloud.Sites
  alias Cloud.Sites.PolicyVersion

  @default_ttl_seconds 600

  @doc "The PubSub topic for a site's policy events: `\"site:<site_id>\"`."
  @spec topic(String.t()) :: String.t()
  def topic(site_id), do: "site:" <> site_id

  @doc """
  Publishes the next policy version for a site in its own transaction and
  broadcasts it after commit. Returns `{:ok, %Cloud.Sites.PolicyVersion{}}`.

  Options: `:published_by` (a `Cloud.Accounts.User` or nil for the system) and
  `:reason` (a short string such as `"manual lock"`).

  Raises if called inside an open transaction: the broadcast must not go out
  before the version is committed. Inside a transaction, use
  `publish_in_transaction/2` and `broadcast/1` after commit.
  """
  @spec publish(String.t(), keyword()) :: {:ok, PolicyVersion.t()} | {:error, term()}
  def publish(site_id, opts \\ []) do
    if Cloud.Repo.in_transaction?() do
      raise ArgumentError, "publish/2 must not run inside a transaction"
    end

    result =
      Cloud.Repo.transaction(fn ->
        case publish_in_transaction(site_id, opts) do
          {:ok, version} -> version
          {:error, error} -> Cloud.Repo.rollback(error)
        end
      end)

    with {:ok, version} <- result do
      broadcast(version)
      {:ok, version}
    end
  end

  @doc """
  Does the work of `publish/2` inside the caller's open transaction, without
  broadcasting.

  It locks the site row (`FOR UPDATE`), so concurrent publishes for one site
  serialise and get distinct, consecutive versions. Everything it reads sees
  the caller's uncommitted changes, which is how an action can publish the
  window it just approved.
  """
  @spec publish_in_transaction(String.t(), keyword()) ::
          {:ok, PolicyVersion.t()} | {:error, term()}
  def publish_in_transaction(site_id, opts \\ []) do
    unless Cloud.Repo.in_transaction?() do
      raise ArgumentError, "publish_in_transaction/2 needs an open transaction"
    end

    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    reason = Keyword.get(opts, :reason, "published")
    published_by_id = user_id(opts[:published_by])

    # these resources have no notifiers; notifications are taken and dropped so ash
    # does not warn about notifications missed inside the transaction
    with {:ok, site} <- Sites.lock_site_for_publish(site_id, authorize?: false),
         {:ok, site, _notifications} <-
           Sites.bump_policy_version(site, authorize?: false, return_notifications?: true),
         {:ok, policy} <- build_policy(site, now),
         {:ok, version, _notifications} <-
           Sites.create_policy_version(
             %{
               site_id: site.id,
               version: site.policy_version,
               policy: Policy.to_map(policy),
               published_by_id: published_by_id,
               reason: reason
             },
             tenant: site.tenant_id,
             authorize?: false,
             return_notifications?: true
           ) do
      {:ok, version}
    end
  end

  @doc """
  Broadcasts `{:policy_published, site_id, version}` for a stored policy
  version. Call it only after the version's transaction committed.
  """
  @spec broadcast(PolicyVersion.t()) :: :ok | {:error, term()}
  def broadcast(%PolicyVersion{site_id: site_id, version: version}) do
    Phoenix.PubSub.broadcast(Cloud.PubSub, topic(site_id), {:policy_published, site_id, version})
  end

  @doc """
  Signs the latest published policy of a site as a fresh `Breakline.Command`
  and returns the wire map (`Breakline.Command.sign/3`).

  Every call signs again with a new nonce, `issued_at` and `expires_at`, for
  the same version. A gateway that was offline when the version was
  published therefore still gets a valid, unexpired command when it
  reconnects.

  Options: `:ttl_seconds` (default #{@default_ttl_seconds}) and `:now` (the
  issue time, default now).

  Returns `{:error, :not_found}` for an unknown site and
  `{:error, :not_published}` when the site has no policy version yet.
  """
  @spec command_for(String.t(), keyword()) :: {:ok, Breakline.Command.wire()} | {:error, term()}
  def command_for(site_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with {:ok, site} <- fetch_site(site_id),
         {:ok, version} <- latest_version(site),
         {:ok, command} <-
           Breakline.Command.new(
             type: "policy",
             site_id: site.id,
             policy_version: version.version,
             payload: version.policy,
             issued_at: opts[:now],
             ttl_seconds: ttl
           ) do
      {:ok, Cloud.Signer.sign(command)}
    end
  end

  @doc """
  The latest stored policy version of a site, read without authorisation.
  Returns `{:error, :not_published}` when there is none.
  """
  @spec latest_policy_version(String.t()) :: {:ok, PolicyVersion.t()} | {:error, term()}
  def latest_policy_version(site_id) do
    with {:ok, site} <- fetch_site(site_id), do: latest_version(site)
  end

  defp fetch_site(site_id) do
    case Sites.get_site(site_id, authorize?: false, not_found_error?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, site} -> {:ok, site}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp latest_version(site) do
    case Sites.latest_policy_version(site.id,
           tenant: site.tenant_id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, nil} -> {:error, :not_published}
      {:ok, version} -> {:ok, version}
      {:error, error} -> {:error, error}
    end
  end

  defp build_policy(site, now) do
    tenant = [tenant: site.tenant_id, authorize?: false]
    # one-off windows that ended more than a day ago (local time) are dropped
    local_cutoff =
      now
      |> DateTime.shift_zone!(site.time_zone, Tz.TimeZoneDatabase)
      |> DateTime.to_naive()
      |> NaiveDateTime.add(-1, :day)
      |> NaiveDateTime.truncate(:second)

    with {:ok, windows} <- Sites.policy_windows(site.id, local_cutoff, tenant),
         {:ok, locks} <- Sites.active_advisory_locks(site.id, now, tenant),
         {:ok, break_glass} <-
           Sites.current_break_glass(site.id, now, [not_found_error?: false] ++ tenant) do
      {recurring, one_off} = Enum.split_with(windows, &(&1.kind == :recurring))

      Policy.new(
        site_id: site.id,
        version: site.policy_version,
        mode: site.mode,
        time_zone: site.time_zone,
        tool_ids: site.tool_ids,
        site_hosts: site.site_hosts,
        recurring_windows:
          Enum.map(recurring, &%{id: &1.id, days: &1.days, starts: &1.starts, ends: &1.ends}),
        one_off_windows:
          Enum.map(one_off, &%{id: &1.id, starts_at: &1.starts_at, ends_at: &1.ends_at}),
        advisory_locks:
          Enum.map(
            locks,
            &%{id: &1.id, reason: &1.reason, source: &1.source, expires_at: &1.expires_at}
          ),
        break_glass: break_glass && break_glass_attrs(break_glass)
      )
      |> case do
        {:ok, policy} -> {:ok, policy}
        {:error, reasons} -> {:error, {:invalid_policy, reasons}}
      end
    end
  end

  defp break_glass_attrs(break_glass) do
    %{until: break_glass.until, approved_by: to_string(break_glass.approved_by.email)}
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(_), do: nil
end
