defmodule Cloud.Accounts.Passkeys do
  @moduledoc """
  Registering and removing a signed-in user's passkeys.

  Registration is our own ceremony, run from the `/account/security`
  LiveView: `registration_options/1` makes a challenge (kept on the server,
  in the LiveView process), the browser calls `navigator.credentials.create`,
  and `register/4` verifies the attestation with `Wax.register/3` and stores
  the passkey.

  The first passkey only needs the password session. Every further passkey
  needs a `:register_passkey` step-up from an existing one, so a stolen
  session cannot add an attacker's passkey and approve with it. Removing a
  passkey needs a `:remove_passkey` step-up (see `Cloud.Accounts.Passkey`).

  Both are recorded in the audit chain of every tenant the user belongs to.
  """

  alias Cloud.Accounts.{Passkey, StepUps, User}
  alias Cloud.WebAuthn

  @timeout_seconds 300

  @doc "The user's passkeys, oldest first."
  @spec list(User.t()) :: [Passkey.t()]
  def list(%User{id: id}), do: Cloud.Accounts.passkeys_for_user!(id, authorize?: false)

  @doc "Whether the user has at least one passkey."
  @spec any?(User.t()) :: boolean()
  def any?(%User{} = user), do: list(user) != []

  @doc """
  A registration challenge for `user` and the json options for
  `navigator.credentials.create`. Keep the challenge on the server and pass it
  to `register/4`.
  """
  @spec registration_options(User.t()) :: {Wax.Challenge.t(), map()}
  def registration_options(%User{} = user) do
    challenge =
      Wax.new_registration_challenge(
        origin: WebAuthn.origin(),
        rp_id: WebAuthn.rp_id(),
        user_verification: WebAuthn.user_verification(),
        attestation: "none",
        timeout: @timeout_seconds
      )

    {:ok, user_handle} = Ecto.UUID.dump(user.id)

    options = %{
      challenge: WebAuthn.encode64(challenge.bytes),
      rp: %{id: WebAuthn.rp_id(), name: WebAuthn.rp_name()},
      user: %{
        id: WebAuthn.encode64(user_handle),
        name: to_string(user.email),
        display_name: to_string(user.email)
      },
      timeout: @timeout_seconds * 1000,
      attestation: "none",
      user_verification: WebAuthn.user_verification(),
      resident_key: "preferred",
      exclude_credentials: Enum.map(list(user), &%{id: WebAuthn.encode64(&1.credential_id)})
    }

    {challenge, options}
  end

  @doc """
  Verifies the browser's attestation for `challenge` and stores the passkey.

  `attestation` holds base64url `"attestation_object"` and
  `"client_data_json"`. Options: `:label` (default `"Passkey"`) and
  `:step_up_id`, required when the user already has a passkey.

  Returns `{:ok, passkey}` or `{:error, reason}`.
  """
  @spec register(User.t(), Wax.Challenge.t(), map(), keyword()) ::
          {:ok, Passkey.t()} | {:error, term()}
  def register(%User{} = user, %Wax.Challenge{} = challenge, attestation, opts \\ []) do
    label = opts[:label] |> to_string() |> String.trim() |> default_label()

    Cloud.Repo.transaction(fn ->
      with {:ok, attestation_object, client_data_json} <- decode(attestation),
           {:ok, {auth_data, _result}} <-
             wax_register(attestation_object, client_data_json, challenge),
           :ok <- step_up_for_another(user, opts[:step_up_id]),
           {:ok, passkey} <- store(user, auth_data, label),
           :ok <-
             Cloud.Audit.append_all(
               Cloud.Audit.tenant_ids(user),
               "passkey.registered",
               %{passkey_id: passkey.id, user_id: user.id, label: passkey.label},
               actor: user
             ) do
        passkey
      else
        {:error, reason} -> Cloud.Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Removes one of the user's passkeys with a verified `:remove_passkey`
  step-up for it. See `Cloud.Accounts.Passkey` for the rules.
  """
  @spec remove(User.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def remove(%User{} = user, passkey_id, step_up_id) do
    with {:ok, passkey} <- Ash.get(Passkey, passkey_id, actor: user) do
      passkey
      |> Ash.Changeset.for_destroy(:destroy, %{step_up_id: step_up_id}, actor: user)
      |> Ash.destroy()
    end
  end

  defp default_label(""), do: "Passkey"
  defp default_label(label), do: String.slice(label, 0, 100)

  defp decode(attestation) when is_map(attestation) do
    with {:ok, attestation_object} <- WebAuthn.decode64(attestation["attestation_object"]),
         {:ok, client_data_json} <- WebAuthn.decode64(attestation["client_data_json"]) do
      {:ok, attestation_object, client_data_json}
    else
      _ -> {:error, :bad_attestation}
    end
  end

  defp decode(_attestation), do: {:error, :bad_attestation}

  defp wax_register(attestation_object, client_data_json, challenge) do
    case Wax.register(attestation_object, client_data_json, challenge) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, {:attestation, error}}
    end
  end

  defp step_up_for_another(user, step_up_id) do
    if any?(user) do
      case StepUps.consume(step_up_id, user, :register_passkey, user.id, %{user_id: user.id}, nil) do
        {:ok, _step_up} -> :ok
        {:error, reason} -> {:error, {:step_up, reason}}
      end
    else
      :ok
    end
  end

  defp store(user, auth_data, label) do
    credential = auth_data.attested_credential_data

    Cloud.Accounts.create_passkey(
      %{
        credential_id: credential.credential_id,
        public_key: credential.credential_public_key,
        sign_count: auth_data.sign_count,
        label: label,
        user_id: user.id
      },
      authorize?: false,
      return_notifications?: true,
      context: %{passkey_ceremony: :verified}
    )
    |> case do
      {:ok, passkey, _notifications} -> {:ok, passkey}
      {:error, error} -> {:error, error}
    end
  end
end
