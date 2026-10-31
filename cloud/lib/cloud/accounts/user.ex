defmodule Cloud.Accounts.User do
  @moduledoc """
  A person who signs in to the cloud.

  - Password sign in (`:password`), with an optional TOTP second factor
    (`:totp`, see `Cloud.Accounts.Totp`). TOTP never approves anything.
  - Passkeys (`:webauthn`, credentials in `Cloud.Accounts.Passkey`): sign in
    without a password, and the only way to verify a step-up
    (`Cloud.Accounts.StepUps`) for an action that opens access. Passkeys are
    added from `/account/security` (`Cloud.Accounts.Passkeys`); the
    strategy's own registration (which would create a passwordless user) is
    off.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at
        auto_confirm_actions [:sign_in_with_magic_link, :reset_password_with_token]
        sender Cloud.Accounts.User.Senders.SendNewUserConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource Cloud.Accounts.Token
      signing_secret Cloud.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender Cloud.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      remember_me :remember_me

      # passkeys sign in and approve. the strategy's register (a new passwordless user)
      # and verify (a session-wide second factor) are off: approvals use our own
      # per-action step-up, see Cloud.Accounts.StepUps
      webauthn :webauthn do
        credential_resource Cloud.Accounts.Passkey
        credentials_relationship_name :passkeys
        rp_id Cloud.Secrets
        rp_name Cloud.Secrets
        origin Cloud.Secrets
        identity_field :email
        user_verification "required"
        resident_key :preferred
        registration_enabled? false
        verify_enabled? false
      end

      # a second factor for password sign in only: no totp sign in on its own
      totp :totp do
        identity_field :email
        issuer "Breakline"
        sign_in_enabled? false
        confirm_setup_enabled? true
        # one period of clock drift between the phone and the server
        grace_period 1
        brute_force_strategy {:preparation, Cloud.Accounts.TotpRateLimit}
      end
    end
  end

  postgres do
    table "users"
    repo Cloud.Repo
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :record_totp_result do
      description "Trusted: counts a wrong totp code, or remembers when a code was accepted."
      require_atomic? false
      accept []
      argument :accepted, :boolean, allow_nil?: false

      change fn changeset, _context ->
        now = DateTime.utc_now()

        if Ash.Changeset.get_argument(changeset, :accepted) do
          # codes from this period or earlier are refused from now on (replay)
          Ash.Changeset.force_change_attributes(changeset,
            last_totp_at: DateTime.truncate(now, :second),
            totp_failed_attempts: 0,
            totp_failed_at: nil
          )
        else
          data = changeset.data
          # failures only add up inside the window
          failures =
            if Cloud.Accounts.Totp.recent?(data.totp_failed_at),
              do: (data.totp_failed_attempts || 0) + 1,
              else: 1

          Ash.Changeset.force_change_attributes(changeset,
            totp_failed_attempts: failures,
            totp_failed_at: now
          )
        end
      end
    end

    update :disable_totp do
      description "Trusted: turns totp off. Cloud.Accounts.Totp.disable/2 checks a code first."
      accept []
      change set_attribute(:totp_secret, nil)
      change set_attribute(:last_totp_at, nil)
    end

    update :change_password do
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token"
        allow_nil? true
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      # generates a remember me token if the remember_me argument is true
      prepare {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenPreparation,
               strategy_name: :remember_me}

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    read :sign_in_with_token do
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    update :reset_password_with_token do
      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :confirmed_at, :utc_datetime_usec

    attribute :totp_secret, :binary do
      sensitive? true
    end

    attribute :last_totp_at, :datetime do
      sensitive? true
    end

    attribute :totp_failed_attempts, :integer do
      allow_nil? false
      default 0
    end

    attribute :totp_failed_at, :utc_datetime_usec
  end

  relationships do
    has_many :passkeys, Cloud.Accounts.Passkey
  end

  identities do
    identity :unique_email, [:email]
  end
end
