defmodule Cloud.Accounts.PasskeysTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias AshAuthentication.{Info, Strategy}
  alias Cloud.Accounts.{Passkey, Passkeys}
  alias Cloud.SoftAuthenticator

  defp register(user, authenticator, opts \\ [], overrides \\ []) do
    {challenge, options} = Passkeys.registration_options(user)
    attestation = SoftAuthenticator.attest(authenticator, options, overrides)
    Passkeys.register(user, challenge, attestation, opts)
  end

  defp audit_actions(tenant) do
    Cloud.Audit.audit_chain!(tenant: tenant, authorize?: false) |> Enum.map(& &1.entry["action"])
  end

  test "registration options bind the challenge to our relying party" do
    user = user!()
    {challenge, options} = Passkeys.registration_options(user)

    assert options.rp == %{id: "localhost", name: "Breakline"}
    assert options.user_verification == "required"
    assert options.challenge == Base.url_encode64(challenge.bytes, padding: false)
    assert challenge.origin == Cloud.WebAuthn.origin()
    assert {:ok, _} = Ecto.UUID.load(Base.url_decode64!(options.user.id, padding: false))
  end

  test "a real attestation registers the passkey and is audited" do
    %{tenant: tenant, approver: user} = org!()
    authenticator = SoftAuthenticator.new()

    assert {:ok, passkey} = register(user, authenticator, label: "work laptop")
    assert passkey.label == "work laptop"
    assert passkey.credential_id == authenticator.credential_id
    assert passkey.public_key[-2] == SoftAuthenticator.cose_key(authenticator)[-2]
    assert [_] = Passkeys.list(user)
    assert "passkey.registered" in audit_actions(tenant)
  end

  test "attestations for another origin, rp id or without user verification are refused" do
    user = user!()

    for overrides <- [
          [origin: "https://evil.example"],
          [rp_id: "evil.example"],
          [user_verified: false]
        ] do
      assert {:error, {:attestation, _}} = register(user, SoftAuthenticator.new(), [], overrides)
    end

    assert Passkeys.list(user) == []
  end

  test "a further passkey needs a step-up from an existing one" do
    user = user!()
    {authenticator, _} = passkey!(user)

    assert {:error, {:step_up, :required}} = register(user, SoftAuthenticator.new())

    {_, step_up} = step_up!(user, authenticator, :register_passkey, user.id, %{user_id: user.id})
    assert {:ok, _} = register(user, SoftAuthenticator.new(), step_up_id: step_up.id)
    assert length(Passkeys.list(user)) == 2
  end

  test "the strategy's own add-credential path cannot store a passkey" do
    user = user!()
    strategy = Info.strategy!(Cloud.Accounts.User, :webauthn)
    {:ok, challenge} = Strategy.WebAuthn.Actions.registration_challenge(strategy, nil)
    authenticator = SoftAuthenticator.new()

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp: %{id: "localhost"}
    }

    attestation = SoftAuthenticator.attest(authenticator, options)

    assert {:error, _} =
             Strategy.action(strategy, :add_credential, attestation,
               challenge: challenge,
               user: user
             )

    assert Passkeys.list(user) == []
  end

  describe "removal" do
    test "needs a step-up from another passkey" do
      user = user!()
      {first_authenticator, first} = passkey!(user)

      {_, add} =
        step_up!(user, first_authenticator, :register_passkey, user.id, %{user_id: user.id})

      {second_authenticator, second} = passkey!(user, step_up_id: add.id)

      assert {:error, error} = Passkeys.remove(user, first.id, nil)
      assert Cloud.Accounts.StepUps.step_up_error?(error)

      # the passkey being removed is not offered for its own removal
      {:ok, step_up, options} =
        Cloud.Accounts.begin_step_up(user, :remove_passkey, first.id, %{id: first.id},
          exclude_passkey_ids: [first.id]
        )

      assert [%{id: offered}] = options.allow_credentials
      assert offered == Base.url_encode64(second.credential_id, padding: false)

      {_, wrong} = SoftAuthenticator.assert(first_authenticator, options)
      assert {:error, :unknown_passkey} = Cloud.Accounts.verify_step_up(step_up.id, wrong)

      {_, step_up} =
        step_up!(user, second_authenticator, :remove_passkey, first.id, %{id: first.id},
          exclude_passkey_ids: [first.id]
        )

      assert :ok = Passkeys.remove(user, first.id, step_up.id)
      assert [%{id: id}] = Passkeys.list(user)
      assert id == second.id
    end

    test "an approver keeps their last passkey" do
      %{tenant: tenant, approver: user} = org!()
      {authenticator, passkey} = passkey!(user)

      {_, step_up} = step_up!(user, authenticator, :remove_passkey, passkey.id, %{id: passkey.id})

      assert {:error, error} = Passkeys.remove(user, passkey.id, step_up.id)
      assert Exception.message(error) =~ "at least one passkey"
      assert [_] = Passkeys.list(user)
      refute "passkey.removed" in audit_actions(tenant)
    end

    test "a user with no role can remove their last passkey with it" do
      user = user!()
      {authenticator, passkey} = passkey!(user)

      {_, step_up} =
        step_up!(user, authenticator, :remove_passkey, passkey.id, %{id: passkey.id},
          exclude_passkey_ids: [passkey.id]
        )

      assert :ok = Passkeys.remove(user, passkey.id, step_up.id)
      assert Passkeys.list(user) == []
    end

    test "nobody removes another user's passkey" do
      user = user!()
      other = user!()
      {_, passkey} = passkey!(user)
      assert {:error, _} = Passkeys.remove(other, passkey.id, nil)
      assert Ash.get!(Passkey, passkey.id, authorize?: false)
    end
  end
end
