defmodule Cloud.Accounts.TotpTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Cloud.Accounts.{Totp, User}

  defp code(secret), do: NimbleTOTP.verification_code(secret)

  # pretends the last accepted code was a minute ago, so the current one is fresh
  defp age_last_code!(user) do
    user = Ash.get!(User, user.id, authorize?: false)
    Ash.Seed.update!(user, %{last_totp_at: DateTime.add(DateTime.utc_now(), -60, :second)})
  end

  defp enable!(user) do
    {:ok, setup} = Totp.begin_setup(user)
    secret = Base.decode32!(setup.secret, padding: false)
    {:ok, _user} = Totp.confirm_setup(user, setup.setup_token, code(secret))
    secret
  end

  defp audit_actions(tenant) do
    Cloud.Audit.audit_chain!(tenant: tenant, authorize?: false) |> Enum.map(& &1.entry["action"])
  end

  test "setup shows an otpauth uri and only stores the secret once confirmed" do
    %{tenant: tenant, admin: user} = org!()
    {:ok, setup} = Totp.begin_setup(user)

    assert setup.uri =~ "otpauth://totp/Breakline:"
    assert setup.uri =~ "secret=#{setup.secret}"
    refute Totp.enabled?(user)

    assert {:error, :invalid_code} = Totp.confirm_setup(user, setup.setup_token, "000000x")
    refute Totp.enabled?(user)

    secret = Base.decode32!(setup.secret, padding: false)
    assert {:ok, _} = Totp.confirm_setup(user, setup.setup_token, code(secret))
    assert Totp.enabled?(user)
    assert Ash.get!(User, user.id, authorize?: false).totp_secret == secret
    assert "totp.enabled" in audit_actions(tenant)
  end

  test "a valid code is accepted once" do
    user = user!()
    secret = enable!(user)

    age_last_code!(user)
    current = code(secret)
    assert :ok = Totp.check_code(user, current)
    assert {:error, :invalid_code} = Totp.check_code(user, current)
  end

  test "five wrong codes lock checks for a while" do
    user = user!()
    secret = enable!(user)

    age_last_code!(user)
    wrong = if code(secret) == "000000", do: "111111", else: "000000"

    for _ <- 1..Totp.max_failures(),
        do: assert({:error, :invalid_code} = Totp.check_code(user, wrong))

    assert {:error, :too_many_attempts} = Totp.check_code(user, code(secret))

    # the strategy's verify action is refused too
    strategy = AshAuthentication.Info.strategy!(User, :totp)
    fresh = Ash.get!(User, user.id, authorize?: false)

    assert {:error, _} =
             AshAuthentication.Strategy.action(
               strategy,
               :verify,
               %{user: fresh, code: code(secret)},
               []
             )

    # outside the window the count starts again
    Ash.Seed.update!(fresh, %{totp_failed_at: DateTime.add(DateTime.utc_now(), -301, :second)})
    assert :ok = Totp.check_code(user, code(secret))
  end

  test "disabling needs a current code and is audited" do
    %{tenant: tenant, approver: user} = org!()
    secret = enable!(user)

    assert {:error, :invalid_code} = Totp.disable(user, "123")
    assert Totp.enabled?(user)

    age_last_code!(user)
    assert {:ok, _} = Totp.disable(user, code(secret))
    refute Totp.enabled?(user)
    assert "totp.disabled" in audit_actions(tenant)
  end
end
