defmodule Cloud.Audit do
  @moduledoc """
  The cloud's own tamper-evident audit chain, one per tenant (threat model T9).

  Every security-relevant action appends a `Cloud.Audit.Entry` in the same
  transaction as the action: windows requested, approved, rejected and
  cancelled, open now, lock now, unlock, advisory locks created and lifted,
  break-glass created and revoked, policy versions published, passkeys
  registered and removed, TOTP enabled and disabled, and step-ups verified
  or failed.

  An entry is a json map with at least `"action"` (for example
  `"window.approved"`), `"at"` (iso8601 utc) and `"actor_id"` (a user id or
  nil for the system), plus the action's essential fields. Secrets (TOTP
  codes and secrets, challenges, signatures) are never recorded.

  Appends for one tenant serialise on the tenant's `Cloud.Audit.Head` row, so
  the chain's seqs are consecutive under concurrency. Resource actions record
  themselves with the `Cloud.Audit.Changes.Record` change; other trusted code
  calls `append/4` inside its transaction or `record/4` outside one.

  `verify/1` checks the whole chain with `Breakline.AuditLog.verify_chain/2`
  against the stored head. The head lives in the same database, so this
  catches edits, deletions and reordering of entries, but not someone who
  rewrites entries and head together; anchoring the head elsewhere is later
  work.
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  alias Breakline.AuditLog
  alias Cloud.Accounts.User
  alias Cloud.Audit.{Entry, Head}

  admin do
    show? true
  end

  resources do
    resource Cloud.Audit.Head do
      define :lock_head, action: :lock, args: [:tenant_id]
      define :advance_head, action: :advance
      define :get_head, action: :read, get_by: [:tenant_id]
    end

    resource Cloud.Audit.Entry do
      define :append_entry, action: :append
      define :audit_chain, action: :chain
    end
  end

  @doc """
  Appends an entry to the tenant's chain inside the caller's open transaction
  and returns `{:ok, %Cloud.Audit.Entry{}}`.

  `action` is the entry's `"action"`, `fields` the action's essential fields
  (atom or string keys, values made json-compatible by `jsonable/1`).
  Options: `:actor` (a `Cloud.Accounts.User`, or nil for the system) and
  `:at` (default now).

  Raises if no transaction is open: the entry must commit with its action.
  """
  @spec append(String.t(), String.t(), map(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def append(tenant_id, action, fields \\ %{}, opts \\ [])
      when is_binary(tenant_id) and is_binary(action) and is_map(fields) do
    unless Cloud.Repo.in_transaction?() do
      raise ArgumentError, "Cloud.Audit.append/4 needs an open transaction"
    end

    actor_id = actor_id(opts[:actor])
    at = Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)

    entry =
      fields
      |> jsonable()
      |> Map.merge(%{
        "action" => action,
        "at" => DateTime.to_iso8601(at),
        "actor_id" => actor_id
      })

    # notifications are taken and dropped: these resources have no notifiers
    with {:ok, head, _} <-
           lock_head(tenant_id, authorize?: false, return_notifications?: true),
         record = AuditLog.append_record(head_tuple(head), entry),
         {:ok, stored, _} <-
           append_entry(
             %{
               seq: record["seq"],
               prev_hash: record["prev_hash"],
               hash: record["hash"],
               entry: record["entry"],
               actor_id: actor_id
             },
             tenant: tenant_id,
             authorize?: false,
             return_notifications?: true
           ),
         {:ok, _head, _} <-
           advance_head(head, %{seq: record["seq"], hash: record["hash"]},
             authorize?: false,
             return_notifications?: true
           ) do
      {:ok, stored}
    end
  end

  @doc """
  Like `append/4`, in a transaction of its own when none is open. For records
  that must survive the caller's failure, such as a failed step-up.
  """
  @spec record(String.t(), String.t(), map(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def record(tenant_id, action, fields \\ %{}, opts \\ []) do
    if Cloud.Repo.in_transaction?() do
      append(tenant_id, action, fields, opts)
    else
      Cloud.Repo.transaction(fn ->
        case append(tenant_id, action, fields, opts) do
          {:ok, entry} -> entry
          {:error, error} -> Cloud.Repo.rollback(error)
        end
      end)
    end
  end

  @doc """
  Appends the same entry to each tenant in `tenant_ids` (see `append/4`), for
  account-level actions such as registering a passkey, which concern every
  tenant the user belongs to.
  """
  @spec append_all([String.t()], String.t(), map(), keyword()) :: :ok | {:error, term()}
  def append_all(tenant_ids, action, fields \\ %{}, opts \\ []) do
    Enum.reduce_while(tenant_ids, :ok, fn tenant_id, :ok ->
      case append(tenant_id, action, fields, opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "The ids of the tenants `user` is a member of, read without authorisation."
  @spec tenant_ids(User.t() | String.t()) :: [String.t()]
  def tenant_ids(%User{id: id}), do: tenant_ids(id)

  def tenant_ids(user_id) when is_binary(user_id) do
    Cloud.Accounts.list_memberships!(
      authorize?: false,
      query: [filter: [user_id: user_id], sort: [tenant_id: :asc]]
    )
    |> Enum.map(& &1.tenant_id)
  end

  @doc """
  Verifies the tenant's whole chain against its stored head.

  Returns `:ok` or `{:error, {:broken_at, seq, reason}}` with the reasons of
  `Breakline.AuditLog.verify_chain/2`.
  """
  @spec verify(String.t()) :: :ok | {:error, {:broken_at, non_neg_integer(), atom()}}
  def verify(tenant_id) when is_binary(tenant_id) do
    entries = audit_chain!(tenant: tenant_id, authorize?: false)

    head =
      case get_head(tenant_id, authorize?: false, not_found_error?: false) do
        {:ok, %Head{} = head} -> head_tuple(head)
        _ -> nil
      end

    entries
    |> Enum.map(&to_record/1)
    |> AuditLog.verify_chain(expected_head: head)
  end

  @doc """
  Makes a map json-compatible for an audit entry: keys become strings, dates
  and times iso8601 strings, atoms strings (except booleans and nil) and
  case-insensitive strings plain strings.
  """
  @spec jsonable(term()) :: term()
  def jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def jsonable(%Date{} = value), do: Date.to_iso8601(value)
  def jsonable(%Time{} = value), do: Time.to_iso8601(value)
  def jsonable(%Ash.CiString{} = value), do: to_string(value)

  def jsonable(%_{} = value),
    do: raise(ArgumentError, "cannot record #{inspect(value.__struct__)} in an audit entry")

  def jsonable(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {to_string(key), jsonable(val)} end)

  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  def jsonable(value) when is_boolean(value) or is_nil(value), do: value
  def jsonable(value) when is_atom(value), do: Atom.to_string(value)
  def jsonable(value), do: value

  defp to_record(%Entry{} = entry) do
    %{
      "seq" => entry.seq,
      "prev_hash" => entry.prev_hash,
      "hash" => entry.hash,
      "entry" => entry.entry
    }
  end

  defp head_tuple(%Head{seq: nil}), do: nil
  defp head_tuple(%Head{seq: seq, hash: hash}), do: {seq, hash}

  defp actor_id(%User{id: id}), do: id
  defp actor_id(_), do: nil
end
