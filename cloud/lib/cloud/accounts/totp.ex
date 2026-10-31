defmodule Cloud.Accounts.Totp do
  @moduledoc """
  TOTP as a second sign-in factor, on top of the password.

  Built on the `totp` strategy of `Cloud.Accounts.User` with two-step setup:
  `begin_setup/1` makes a secret and returns the `otpauth://` uri and a setup
  token (the secret is not stored yet), and `confirm_setup/3` stores it once
  the user typed a valid code from their app.

  When a user has TOTP, password sign in asks for a code before the session
  is created (`CloudWeb.AuthLive.SignIn`). `check_code/2` counts failures:
  after five wrong codes in five minutes every check fails until the window
  passes (`Cloud.Accounts.TotpRateLimit` enforces the same on the strategy's
  verify action). A code is accepted once: the time of the last accepted code
  is kept and older codes are refused.

  TOTP only signs in. It never approves anything that opens access (threat
  model T5): step-ups are passkey-only.

  Enabling and disabling are recorded in the audit chain of every tenant the
  user belongs to.
  """

  alias AshAuthentication.{Info, Strategy}
  alias Cloud.Accounts.User

  @max_failures 5
  @window_seconds 300

  @doc "The maximum failed codes in the window before checks are refused."
  def max_failures, do: @max_failures

  @doc "Whether the user has TOTP enabled (read fresh from the database)."
  @spec enabled?(User.t()) :: boolean()
  def enabled?(%User{id: id}) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, user} -> not is_nil(user.totp_secret)
      _ -> false
    end
  end

  @doc """
  Starts TOTP setup. Returns `{:ok, %{uri: otpauth_uri, secret: base32, setup_token: token}}`.
  The secret is only stored by `confirm_setup/3`.
  """
  @spec begin_setup(User.t()) :: {:ok, map()} | {:error, term()}
  def begin_setup(%User{} = user) do
    if enabled?(user) do
      {:error, :already_enabled}
    else
      with {:ok, user} <- Strategy.action(strategy(), :setup, %{user: user}, []) do
        uri = user.__metadata__.totp_url
        secret = uri |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("secret")
        {:ok, %{uri: uri, secret: secret, setup_token: user.__metadata__.setup_token}}
      end
    end
  end

  @doc """
  Confirms setup with a code from the user's app and stores the secret.
  Returns `{:ok, user}` or `{:error, :invalid_code | term()}`.
  """
  @spec confirm_setup(User.t(), String.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def confirm_setup(%User{} = user, setup_token, code) when is_binary(code) do
    strategy = strategy()

    # the strategy's confirm_setup action, run like Strategy.action/4 does, but with
    # its notifications (the setup token's revocation) sent after our transaction
    result =
      Cloud.Repo.transaction(fn ->
        with {:ok, user, notifications} <-
               user
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
               |> Ash.Changeset.for_update(
                 strategy.confirm_setup_action_name,
                 %{setup_token: setup_token, code: String.trim(code)},
                 domain: Cloud.Accounts
               )
               |> Ash.update(return_notifications?: true),
             :ok <- audit(user, "totp.enabled") do
          {user, notifications}
        else
          {:error, error} -> Cloud.Repo.rollback(error)
        end
      end)

    case result do
      {:ok, {user, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, user}

      {:error, _error} ->
        {:error, :invalid_code}
    end
  end

  def confirm_setup(_user, _setup_token, _code), do: {:error, :invalid_code}

  @doc """
  Checks a code for a user with TOTP enabled, counting failures.

  Returns `:ok`, `{:error, :invalid_code}` or `{:error, :too_many_attempts}`.
  """
  @spec check_code(User.t(), String.t()) :: :ok | {:error, :invalid_code | :too_many_attempts}
  def check_code(%User{id: id}, code) when is_binary(code) do
    user = Ash.get!(User, id, authorize?: false)

    cond do
      is_nil(user.totp_secret) ->
        {:error, :invalid_code}

      locked?(user) ->
        {:error, :too_many_attempts}

      true ->
        case Strategy.action(strategy(), :verify, %{user: user, code: String.trim(code)}, []) do
          {:ok, true} ->
            Cloud.Accounts.record_totp_result!(user, %{accepted: true}, authorize?: false)
            :ok

          _ ->
            Cloud.Accounts.record_totp_result!(user, %{accepted: false}, authorize?: false)
            {:error, :invalid_code}
        end
    end
  end

  def check_code(_user, _code), do: {:error, :invalid_code}

  @doc """
  Turns TOTP off after checking a current code. Returns `{:ok, user}` or the
  error of `check_code/2`.
  """
  @spec disable(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def disable(%User{} = user, code) do
    with :ok <- check_code(user, code) do
      Cloud.Repo.transaction(fn ->
        user = Ash.get!(User, user.id, authorize?: false)

        with {:ok, user, _notifications} <-
               Cloud.Accounts.disable_totp(user, authorize?: false, return_notifications?: true),
             :ok <- audit(user, "totp.disabled") do
          user
        else
          {:error, error} -> Cloud.Repo.rollback(error)
        end
      end)
    end
  end

  @doc """
  Whether the user has had too many failed codes recently. Used by
  `check_code/2` and `Cloud.Accounts.TotpRateLimit`.
  """
  @spec locked?(User.t()) :: boolean()
  def locked?(%User{totp_failed_attempts: failures, totp_failed_at: failed_at})
      when is_integer(failures) and failures >= @max_failures,
      do: recent?(failed_at)

  def locked?(_user), do: false

  @doc "Whether a failure at `failed_at` is still inside the counting window."
  @spec recent?(DateTime.t() | nil) :: boolean()
  def recent?(nil), do: false

  def recent?(%DateTime{} = failed_at),
    do: DateTime.diff(DateTime.utc_now(), failed_at, :second) < @window_seconds

  defp audit(user, action) do
    Cloud.Audit.append_all(Cloud.Audit.tenant_ids(user), action, %{user_id: user.id}, actor: user)
  end

  defp strategy, do: Info.strategy!(User, :totp)
end
