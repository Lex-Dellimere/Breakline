defmodule Cloud.Accounts.StepUps do
  @moduledoc """
  The step-up ceremony: a passkey assertion bound to one action (T5).

  1. `begin/5` creates a `Cloud.Accounts.StepUp` for a purpose, a subject and
     the action's parameters, and returns WebAuthn request options with its
     challenge, allowing only the user's passkeys.
  2. The browser calls `navigator.credentials.get` with those options.
  3. `verify/3` checks the assertion with `Wax.authenticate/6` against the
     user's stored passkey: signature, challenge, origin, rp id, user
     verification (required) and a signature counter that must move forward.
     It sets `verified_at`, or `failed_at` on any failure.
  4. The action consumes the step-up in its own transaction
     (`Cloud.Accounts.Changes.RequireStepUp`, or `consume/6` for trusted
     code that composes several actions).

  A TOTP code never satisfies a step-up: only a passkey assertion verifies
  one.

  Verifications and failures are recorded in the tenant's audit chain (every
  tenant of the user for account-level purposes).
  """

  require Ash.Query

  alias Breakline.CanonicalJSON
  alias Cloud.Accounts.{Passkey, StepUp, User}
  alias Cloud.WebAuthn

  @ttl_seconds 120
  # trusted writes inside a transaction; these resources have no notifiers
  @quiet [authorize?: false, return_notifications?: true]
  @site_purposes [:open_window, :approve_window, :break_glass, :lift_lock]
  @account_purposes [:remove_passkey, :register_passkey]

  @doc "How long a step-up stays valid, in seconds."
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Starts a step-up for `user`.

  `purpose` is one of `Cloud.Accounts.StepUp.purposes/0`, `subject_id` the id
  the action works on (a site, window, lock or passkey) and `params` the
  action's parameters exactly as the action will see them (see
  `payload_hash/1`).

  Options:

  - `:tenant` (required for site purposes): the tenant id or struct. The user
    must be an admin or approver there.
  - `:exclude_passkey_ids`: passkeys that may not answer, for example the one
    being removed. When that would leave none, the excluded ones are allowed
    after all.

  Returns `{:ok, step_up, options}` where `options` is the json map the
  browser hook turns into `PublicKeyCredentialRequestOptions`, or
  `{:error, :no_passkey | :forbidden | :tenant_required}`.
  """
  @spec begin(User.t(), atom(), String.t(), map(), keyword()) ::
          {:ok, StepUp.t(), map()} | {:error, atom()}
  def begin(%User{} = user, purpose, subject_id, params, opts \\ [])
      when purpose in @site_purposes or purpose in @account_purposes do
    with {:ok, tenant_id} <- begin_tenant(user, purpose, opts),
         {:ok, passkeys} <- allowed_passkeys(user, opts[:exclude_passkey_ids] || []) do
      challenge = :crypto.strong_rand_bytes(32)

      step_up =
        Cloud.Accounts.create_step_up!(
          %{
            user_id: user.id,
            tenant_id: tenant_id,
            purpose: purpose,
            subject_id: subject_id,
            payload_hash: payload_hash(params),
            challenge: challenge,
            allowed_credential_ids: Enum.map(passkeys, & &1.credential_id),
            expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
          },
          authorize?: false
        )

      {:ok, step_up, request_options(challenge, passkeys)}
    end
  end

  @doc """
  The WebAuthn request options for a challenge and the passkeys that may
  answer it, as json for the browser hook.
  """
  @spec request_options(binary(), [Passkey.t()]) :: map()
  def request_options(challenge, passkeys) do
    %{
      challenge: WebAuthn.encode64(challenge),
      rp_id: WebAuthn.rp_id(),
      timeout: @ttl_seconds * 1000,
      user_verification: WebAuthn.user_verification(),
      allow_credentials:
        Enum.map(passkeys, &%{id: WebAuthn.encode64(&1.credential_id), type: "public-key"})
    }
  end

  @doc """
  Verifies the browser's assertion for a step-up.

  `assertion` is the map the hook pushes: base64url `"raw_id"`,
  `"authenticator_data"`, `"signature"` and `"client_data_json"`.

  Options: `:actor`, when given, must be the step-up's user.

  Returns `{:ok, step_up}` with `verified_at` set, or `{:error, reason}`.
  Any failure after the step-up was found kills it (`failed_at`) and is
  recorded as `"step_up.failed"`.
  """
  @spec verify(String.t(), map(), keyword()) :: {:ok, StepUp.t()} | {:error, atom()}
  def verify(step_up_id, assertion, opts \\ []) do
    result =
      Cloud.Repo.transaction(fn ->
        with {:ok, step_up} <- lock(step_up_id),
             :ok <- verifiable(step_up, opts[:actor]),
             {:ok, verified} <- check_assertion(step_up, assertion) do
          verified
        else
          {:error, reason} -> Cloud.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, step_up} ->
        {:ok, step_up}

      {:error, reason} ->
        record_failure(step_up_id, reason, opts[:actor])
        {:error, reason}
    end
  end

  @doc """
  Consumes a verified step-up for an action, inside the caller's open
  transaction. Returns `{:ok, step_up}` or `{:error, reason}`.

  The step-up must be the actor's, verified, unexpired and unused, and its
  purpose, subject, tenant (when the step-up has one) and payload hash must
  match exactly.
  """
  @spec consume(String.t() | nil, User.t() | nil, atom(), String.t(), map(), String.t() | nil) ::
          {:ok, StepUp.t()} | {:error, atom()}
  def consume(step_up_id, actor, purpose, subject_id, params, tenant_id) do
    unless Cloud.Repo.in_transaction?() do
      raise ArgumentError, "consume/6 needs an open transaction"
    end

    with {:ok, step_up} <- lock(step_up_id),
         :ok <- matches(step_up, actor, purpose, subject_id, tenant_id),
         :ok <- same_payload(step_up, params),
         :ok <- usable(step_up) do
      {consumed, _notifications} = Cloud.Accounts.consume_step_up!(step_up, @quiet)
      {:ok, consumed}
    end
  end

  @doc """
  Checks a step-up a trusted caller already consumed in this transaction
  (see `Cloud.Accounts.Changes.RequireStepUp`).
  """
  @spec check_consumed(StepUp.t(), User.t() | nil, atom(), String.t()) ::
          {:ok, StepUp.t()} | {:error, atom()}
  def check_consumed(%StepUp{} = step_up, actor, purpose, subject_id) do
    cond do
      is_nil(step_up.consumed_at) -> {:error, :not_verified}
      not match?(%User{}, actor) or step_up.user_id != actor.id -> {:error, :wrong_user}
      step_up.purpose != purpose -> {:error, :wrong_purpose}
      step_up.subject_id != subject_id -> {:error, :wrong_subject}
      true -> {:ok, step_up}
    end
  end

  @doc """
  The sha256 (lowercase hex) of an action's canonical parameters.

  Keys become strings and nil values are dropped. `DateTime`s become unix
  microseconds, so the precision a value was cast with does not matter;
  naive datetimes, dates and times become iso8601, atoms strings, and lists
  keep their order.
  """
  @spec payload_hash(map()) :: String.t()
  def payload_hash(params) when is_map(params) do
    json = params |> canonical() |> CanonicalJSON.encode!()
    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end

  @doc "The error an action fails with when its step-up is rejected."
  @spec error(atom()) :: Exception.t()
  def error(reason) do
    Ash.Error.Changes.InvalidArgument.exception(field: :step_up_id, message: message(reason))
  end

  @doc "Whether an Ash error is (or contains) a rejected step-up."
  @spec step_up_error?(term()) :: boolean()
  def step_up_error?(%Ash.Error.Changes.InvalidArgument{field: :step_up_id}), do: true

  def step_up_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &step_up_error?/1)

  def step_up_error?(_error), do: false

  @doc "A readable sentence for a step-up failure reason."
  @spec message(atom()) :: String.t()
  def message(:required), do: "this needs a fresh passkey approval"
  def message(:not_found), do: "the passkey approval was not found"
  def message(:wrong_user), do: "the passkey approval belongs to someone else"
  def message(:wrong_purpose), do: "the passkey approval was for a different kind of action"
  def message(:wrong_subject), do: "the passkey approval was for a different site or record"
  def message(:wrong_tenant), do: "the passkey approval was for a different organisation"
  def message(:params_changed), do: "the action changed after it was approved"
  def message(:not_verified), do: "the passkey approval was not completed"
  def message(:expired), do: "the passkey approval expired, try again"
  def message(:already_used), do: "the passkey approval was already used"
  def message(:already_verified), do: "the passkey approval was already completed"
  def message(:failed), do: "the passkey approval failed, start again"
  def message(:no_passkey), do: "register a passkey first"
  def message(:forbidden), do: "your role does not allow that"
  def message(:unknown_passkey), do: "that passkey is not allowed here"
  def message(:sign_count), do: "the passkey's signature counter went backwards"
  def message(:bad_assertion), do: "the passkey response was malformed"
  def message(:invalid_signature), do: "the passkey response did not verify"
  def message(_reason), do: "the passkey approval did not work"

  # begin

  defp begin_tenant(_user, purpose, _opts) when purpose in @account_purposes, do: {:ok, nil}

  defp begin_tenant(user, _purpose, opts) do
    case tenant_id(opts[:tenant]) do
      nil ->
        {:error, :tenant_required}

      tenant_id ->
        case Cloud.Accounts.membership_for(user.id, tenant_id, authorize?: false) do
          {:ok, %{role: role}} when role in [:admin, :approver] -> {:ok, tenant_id}
          _ -> {:error, :forbidden}
        end
    end
  end

  defp tenant_id(%{id: id}), do: id
  defp tenant_id(id) when is_binary(id), do: id
  defp tenant_id(_), do: nil

  defp allowed_passkeys(user, exclude) do
    case Cloud.Accounts.passkeys_for_user!(user.id, authorize?: false) do
      [] ->
        {:error, :no_passkey}

      passkeys ->
        case Enum.reject(passkeys, &(&1.id in exclude)) do
          [] -> {:ok, passkeys}
          allowed -> {:ok, allowed}
        end
    end
  end

  # verify

  defp lock(nil), do: {:error, :required}

  defp lock(step_up_id) do
    case Ecto.UUID.cast(step_up_id) do
      {:ok, _} ->
        case Cloud.Accounts.lock_step_up(step_up_id, authorize?: false, not_found_error?: false) do
          {:ok, %StepUp{} = step_up} -> {:ok, step_up}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp verifiable(step_up, actor) do
    cond do
      actor != nil and (not match?(%User{}, actor) or actor.id != step_up.user_id) ->
        {:error, :wrong_user}

      step_up.failed_at ->
        {:error, :failed}

      step_up.consumed_at ->
        {:error, :already_used}

      step_up.verified_at ->
        {:error, :already_verified}

      expired?(step_up) ->
        {:error, :expired}

      true ->
        :ok
    end
  end

  defp check_assertion(step_up, assertion) do
    with {:ok, raw_id, auth_data_bin, signature, client_data_json} <- decode(assertion),
         {:ok, passkey} <- passkey_for(step_up, raw_id),
         {:ok, auth_data} <-
           authenticate(step_up, passkey, raw_id, auth_data_bin, signature, client_data_json),
         :ok <- sign_count_moved(passkey, auth_data.sign_count) do
      Cloud.Accounts.record_passkey_use!(
        passkey,
        %{sign_count: auth_data.sign_count, last_used_at: DateTime.utc_now()},
        @quiet
      )

      {verified, _notifications} =
        Cloud.Accounts.mark_step_up_verified!(step_up, %{passkey_id: passkey.id}, @quiet)

      case audit(verified, "step_up.verified", %{passkey_id: passkey.id}) do
        :ok -> {:ok, verified}
        {:error, _} -> {:error, :audit_failed}
      end
    end
  end

  defp decode(assertion) when is_map(assertion) do
    with {:ok, raw_id} <- WebAuthn.decode64(assertion["raw_id"]),
         {:ok, auth_data} <- WebAuthn.decode64(assertion["authenticator_data"]),
         {:ok, signature} <- WebAuthn.decode64(assertion["signature"]),
         {:ok, client_data_json} <- WebAuthn.decode64(assertion["client_data_json"]) do
      {:ok, raw_id, auth_data, signature, client_data_json}
    else
      _ -> {:error, :bad_assertion}
    end
  end

  defp decode(_assertion), do: {:error, :bad_assertion}

  defp passkey_for(step_up, raw_id) do
    with true <- raw_id in step_up.allowed_credential_ids,
         {:ok, [passkey]} <-
           Passkey
           |> Ash.Query.filter(credential_id == ^raw_id and user_id == ^step_up.user_id)
           |> Ash.read(authorize?: false) do
      {:ok, passkey}
    else
      _ -> {:error, :unknown_passkey}
    end
  end

  defp authenticate(step_up, passkey, raw_id, auth_data_bin, signature, client_data_json) do
    credentials = [{passkey.credential_id, passkey.public_key}]

    challenge =
      Wax.new_authentication_challenge(
        bytes: step_up.challenge,
        origin: WebAuthn.origin(),
        rp_id: WebAuthn.rp_id(),
        user_verification: WebAuthn.user_verification(),
        allow_credentials: credentials,
        timeout: @ttl_seconds
      )

    # the challenge was issued when the step-up began, not now
    challenge = %{challenge | issued_at: DateTime.to_unix(step_up.inserted_at)}

    case Wax.authenticate(
           raw_id,
           auth_data_bin,
           signature,
           client_data_json,
           challenge,
           credentials
         ) do
      {:ok, auth_data} -> {:ok, auth_data}
      {:error, %Wax.InvalidSignatureError{}} -> {:error, :invalid_signature}
      {:error, %Wax.ExpiredChallengeError{}} -> {:error, :expired}
      {:error, error} -> {:error, wax_reason(error)}
    end
  end

  defp wax_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp wax_reason(_error), do: :invalid_assertion

  # a counter of 0 on both sides means the authenticator does not count;
  # otherwise it must move forward, or the passkey may have been cloned
  defp sign_count_moved(%Passkey{sign_count: 0}, 0), do: :ok
  defp sign_count_moved(%Passkey{sign_count: stored}, new) when new > stored, do: :ok
  defp sign_count_moved(_passkey, _new), do: {:error, :sign_count}

  defp record_failure(step_up_id, reason, _actor)
       when reason not in [:not_found, :required, :wrong_user, :failed, :already_used] do
    Cloud.Repo.transaction(fn ->
      with {:ok, step_up} <- lock(step_up_id),
           nil <- step_up.failed_at do
        {step_up, _notifications} = Cloud.Accounts.mark_step_up_failed!(step_up, @quiet)
        audit(step_up, "step_up.failed", %{reason: reason})
      end
    end)

    :ok
  end

  defp record_failure(_step_up_id, _reason, _actor), do: :ok

  defp audit(step_up, action, fields) do
    tenant_ids =
      case step_up.tenant_id do
        nil -> Cloud.Audit.tenant_ids(step_up.user_id)
        tenant_id -> [tenant_id]
      end

    fields =
      Map.merge(fields, %{
        step_up_id: step_up.id,
        user_id: step_up.user_id,
        purpose: step_up.purpose,
        subject_id: step_up.subject_id
      })

    Cloud.Audit.append_all(tenant_ids, action, fields, actor: user_stub(step_up.user_id))
  end

  # the audit only needs the actor's id
  defp user_stub(user_id), do: %User{id: user_id}

  # consume

  defp matches(step_up, actor, purpose, subject_id, tenant_id) do
    cond do
      not match?(%User{}, actor) or step_up.user_id != actor.id -> {:error, :wrong_user}
      step_up.purpose != purpose -> {:error, :wrong_purpose}
      step_up.subject_id != subject_id -> {:error, :wrong_subject}
      step_up.tenant_id != nil and step_up.tenant_id != tenant_id -> {:error, :wrong_tenant}
      true -> :ok
    end
  end

  defp same_payload(step_up, params) do
    if step_up.payload_hash == payload_hash(params), do: :ok, else: {:error, :params_changed}
  end

  defp usable(step_up) do
    cond do
      step_up.consumed_at -> {:error, :already_used}
      step_up.failed_at -> {:error, :failed}
      is_nil(step_up.verified_at) -> {:error, :not_verified}
      expired?(step_up) -> {:error, :expired}
      true -> :ok
    end
  end

  defp expired?(step_up), do: DateTime.compare(DateTime.utc_now(), step_up.expires_at) != :lt

  defp canonical(params) when is_map(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), canonical_value(value)} end)
  end

  defp canonical_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  # precision is normalised to microseconds so ~N[...] and a cast value agree
  defp canonical_value(%NaiveDateTime{microsecond: {us, _}} = value),
    do: NaiveDateTime.to_iso8601(%{value | microsecond: {us, 6}})

  defp canonical_value(%Date{} = value), do: Date.to_iso8601(value)

  defp canonical_value(%Time{microsecond: {us, _}} = value),
    do: Time.to_iso8601(%{value | microsecond: {us, 6}})

  defp canonical_value(%Ash.CiString{} = value), do: to_string(value)
  defp canonical_value(value) when is_map(value), do: canonical(value)
  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value) when is_boolean(value), do: value
  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_value(value), do: value
end
