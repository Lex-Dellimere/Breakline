defmodule Cloud.Accounts.StepUpsTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Cloud.Access
  alias Cloud.Accounts
  alias Cloud.Accounts.{StepUp, StepUps}
  alias Cloud.SoftAuthenticator
  alias Cloud.Sites

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin)
    {authenticator, passkey} = passkey!(admin)
    Map.merge(org, %{site: site, authenticator: authenticator, passkey: passkey})
  end

  defp open_params(site, minutes \\ 30), do: Access.step_up_params(site.id, {:open, minutes})

  defp begin_open(ctx, minutes \\ 30) do
    {:ok, step_up, options} =
      Accounts.begin_step_up(ctx.admin, :open_window, ctx.site.id, open_params(ctx.site, minutes),
        tenant: ctx.tenant
      )

    {step_up, options}
  end

  defp verified_open(ctx, minutes \\ 30) do
    {step_up, options} = begin_open(ctx, minutes)
    {_authenticator, assertion} = SoftAuthenticator.assert(ctx.authenticator, options)
    {:ok, step_up} = Accounts.verify_step_up(step_up.id, assertion, actor: ctx.admin)
    step_up
  end

  defp reload(step_up), do: Ash.get!(StepUp, step_up.id, authorize?: false)

  defp rejected?(result, reason) do
    case result do
      {:error, error} ->
        StepUps.step_up_error?(error) and Exception.message(error) =~ StepUps.message(reason)

      _ ->
        false
    end
  end

  describe "begin and verify" do
    test "begin returns request options for the user's passkeys only", ctx do
      {step_up, options} = begin_open(ctx)

      assert step_up.purpose == :open_window
      assert step_up.subject_id == ctx.site.id
      assert step_up.tenant_id == ctx.tenant.id
      assert step_up.payload_hash == StepUps.payload_hash(open_params(ctx.site))
      assert DateTime.diff(step_up.expires_at, DateTime.utc_now()) in 115..120
      assert options.rp_id == "localhost"
      assert options.user_verification == "required"
      assert options.challenge == Base.url_encode64(step_up.challenge, padding: false)

      assert [%{id: id}] = options.allow_credentials
      assert id == Base.url_encode64(ctx.passkey.credential_id, padding: false)
    end

    test "begin needs a passkey and an admin or approver of the tenant", ctx do
      no_passkey = user!()
      member!(no_passkey, ctx.tenant, :approver)

      assert {:error, :no_passkey} =
               Accounts.begin_step_up(no_passkey, :open_window, ctx.site.id, %{},
                 tenant: ctx.tenant
               )

      other = org!()

      assert {:error, :forbidden} =
               Accounts.begin_step_up(ctx.admin, :open_window, ctx.site.id, %{},
                 tenant: other.tenant
               )

      assert {:error, :tenant_required} =
               Accounts.begin_step_up(ctx.admin, :open_window, ctx.site.id, %{})
    end

    test "a real assertion verifies, moves the counter and is audited", ctx do
      step_up = verified_open(ctx)

      assert step_up.verified_at
      assert step_up.passkey_id == ctx.passkey.id
      passkey = Ash.get!(Accounts.Passkey, ctx.passkey.id, authorize?: false)
      assert passkey.sign_count == 1
      assert passkey.last_used_at

      actions =
        Enum.map(
          Cloud.Audit.audit_chain!(tenant: ctx.tenant, authorize?: false),
          & &1.entry["action"]
        )

      assert "step_up.verified" in actions
    end

    test "a bad signature fails and kills the step-up", ctx do
      {step_up, options} = begin_open(ctx)

      {_authenticator, assertion} =
        SoftAuthenticator.assert(ctx.authenticator, options, tamper_signature: true)

      assert {:error, :invalid_signature} = Accounts.verify_step_up(step_up.id, assertion)
      assert reload(step_up).failed_at

      # a good assertion afterwards does not revive it
      {_authenticator, good} = SoftAuthenticator.assert(ctx.authenticator, options)
      assert {:error, :failed} = Accounts.verify_step_up(step_up.id, good)

      entries = Cloud.Audit.audit_chain!(tenant: ctx.tenant, authorize?: false)

      assert %{"reason" => "invalid_signature"} =
               Enum.find(entries, &(&1.entry["action"] == "step_up.failed")).entry
    end

    test "the origin, rp id, user verification and challenge are checked", ctx do
      for {overrides, reason} <- [
            {[origin: "https://evil.example"], :origin_mismatch},
            {[rp_id: "evil.example"], :rp_id_mismatch},
            {[user_verified: false], :user_not_verified},
            {[challenge: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)],
             :challenge_mismatch}
          ] do
        {step_up, options} = begin_open(ctx)

        {_authenticator, assertion} =
          SoftAuthenticator.assert(ctx.authenticator, options, overrides)

        assert {:error, ^reason} = Accounts.verify_step_up(step_up.id, assertion)
        assert reload(step_up).failed_at
        refute reload(step_up).verified_at
      end
    end

    test "a signature counter that does not move forward is refused", ctx do
      {step_up, options} = begin_open(ctx)

      {authenticator, assertion} =
        SoftAuthenticator.assert(ctx.authenticator, options, sign_count: 5)

      assert {:ok, _} = Accounts.verify_step_up(step_up.id, assertion)

      # a clone replaying an older counter
      {step_up, options} = begin_open(ctx)
      {_, assertion} = SoftAuthenticator.assert(authenticator, options, sign_count: 5)
      assert {:error, :sign_count} = Accounts.verify_step_up(step_up.id, assertion)
    end

    test "another user's passkey cannot answer", ctx do
      other = user!()
      member!(other, ctx.tenant, :approver)
      {other_authenticator, _} = passkey!(other)

      {step_up, options} = begin_open(ctx)
      {_, assertion} = SoftAuthenticator.assert(other_authenticator, options)
      assert {:error, :unknown_passkey} = Accounts.verify_step_up(step_up.id, assertion)

      # and another user cannot verify someone else's step-up
      {step_up, options} = begin_open(ctx)
      {_, assertion} = SoftAuthenticator.assert(ctx.authenticator, options)
      assert {:error, :wrong_user} = Accounts.verify_step_up(step_up.id, assertion, actor: other)
      refute reload(step_up).failed_at
    end

    test "an expired step-up does not verify", ctx do
      {step_up, options} = begin_open(ctx)

      Ash.Seed.update!(step_up, %{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

      {_, assertion} = SoftAuthenticator.assert(ctx.authenticator, options)
      assert {:error, :expired} = Accounts.verify_step_up(step_up.id, assertion)
    end

    test "a TOTP code is not an assertion", ctx do
      secret = NimbleTOTP.secret()
      Ash.Seed.update!(ctx.admin, %{totp_secret: secret})
      {step_up, _options} = begin_open(ctx)

      code = NimbleTOTP.verification_code(secret)
      assert {:error, :bad_assertion} = Accounts.verify_step_up(step_up.id, %{"code" => code})
      refute reload(step_up).verified_at

      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id), :failed)
      assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
    end
  end

  describe "enforcement" do
    test "open_now runs with a verified step-up and consumes it", ctx do
      step_up = verified_open(ctx)

      assert {:ok, %{policy_version: %{version: 1}}} =
               Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id)

      assert reload(step_up).consumed_at
    end

    test "open_now without a step-up fails", ctx do
      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, nil), :required)

      assert rejected?(
               Access.open_now(ctx.site.id, 30, ctx.admin, Ash.UUID.generate()),
               :not_found
             )

      assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
    end

    test "another user's step-up is refused", ctx do
      approver = ctx.approver
      {approver_authenticator, _} = passkey!(approver)

      {_, step_up} =
        step_up!(
          approver,
          approver_authenticator,
          :open_window,
          ctx.site.id,
          open_params(ctx.site),
          tenant: ctx.tenant
        )

      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id), :wrong_user)
      refute reload(step_up).consumed_at
    end

    test "a step-up for another purpose is refused", ctx do
      {_, step_up} =
        step_up!(ctx.admin, ctx.authenticator, :break_glass, ctx.site.id, open_params(ctx.site),
          tenant: ctx.tenant
        )

      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id), :wrong_purpose)
    end

    test "a step-up for another site is refused", ctx do
      other_site = site!(ctx.tenant, ctx.admin)

      {_, step_up} =
        step_up!(ctx.admin, ctx.authenticator, :open_window, other_site.id, open_params(ctx.site),
          tenant: ctx.tenant
        )

      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id), :wrong_subject)
    end

    test "changed parameters are refused (payload hash)", ctx do
      step_up = verified_open(ctx, 15)
      assert rejected?(Access.open_now(ctx.site.id, 60, ctx.admin, step_up.id), :params_changed)
      refute reload(step_up).consumed_at

      # the approved minutes still work
      assert {:ok, _} = Access.open_now(ctx.site.id, 15, ctx.admin, step_up.id)
    end

    test "an expired step-up is refused", ctx do
      step_up = verified_open(ctx)
      Ash.Seed.update!(step_up, %{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id), :expired)
    end

    test "an unverified step-up is refused", ctx do
      {step_up, _options} = begin_open(ctx)
      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id), :not_verified)
    end

    test "a step-up is used once", ctx do
      step_up = verified_open(ctx)
      assert {:ok, _} = Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id)
      assert rejected?(Access.open_now(ctx.site.id, 30, ctx.admin, step_up.id), :already_used)
      assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 1
    end

    test "a failed action does not spend the step-up", ctx do
      {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "a")
      {approver_authenticator, _} = passkey!(ctx.approver)

      {_, step_up} =
        step_up!(
          ctx.approver,
          approver_authenticator,
          :lift_lock,
          ctx.site.id,
          Access.step_up_params(ctx.site.id, :unlock),
          tenant: ctx.tenant
        )

      # unlock consumes the step-up, then lifting is forbidden to an approver:
      # the whole transaction rolls back, consumption included
      assert {:error, %Ash.Error.Forbidden{}} =
               Access.unlock(ctx.site.id, ctx.approver, step_up.id)

      refute reload(step_up).consumed_at
    end

    test "trusted code with authorize?: false still needs a step-up", ctx do
      assert rejected?(
               Sites.open_window_now(%{site_id: ctx.site.id, minutes: 30},
                 authorize?: false,
                 tenant: ctx.tenant
               ),
               :required
             )
    end

    test "approve, book, break-glass and lift each need their own step-up", ctx do
      opts = [actor: ctx.admin, tenant: ctx.tenant]
      window = Sites.request_window!(recurring_attrs(ctx.site), opts)
      assert rejected?(Sites.approve_window(window, opts), :required)

      {auth, wrong} =
        step_up!(ctx.admin, ctx.authenticator, :approve_window, window.id, %{id: window.id},
          tenant: ctx.tenant
        )

      assert rejected?(
               Sites.approve_window(window, %{step_up_id: wrong.id}, opts),
               :params_changed
             )

      {auth, right} =
        step_up!(ctx.admin, auth, :approve_window, window.id, approve_params(window),
          tenant: ctx.tenant
        )

      assert {:ok, %{status: :approved}} =
               Sites.approve_window(window, %{step_up_id: right.id}, opts)

      assert rejected?(Sites.create_approved_window(one_off_attrs(ctx.site), opts), :required)

      until = DateTime.add(DateTime.utc_now(), 600)

      assert rejected?(
               Sites.create_break_glass(%{site_id: ctx.site.id, until: until}, opts),
               :required
             )

      {auth, bg} =
        step_up!(
          ctx.admin,
          auth,
          :break_glass,
          ctx.site.id,
          %{site_id: ctx.site.id, until: until},
          tenant: ctx.tenant
        )

      # a different end time is a different approval
      assert rejected?(
               Sites.create_break_glass(
                 %{site_id: ctx.site.id, until: DateTime.add(until, 3600), step_up_id: bg.id},
                 opts
               ),
               :params_changed
             )

      assert {:ok, _} =
               Sites.create_break_glass(
                 %{site_id: ctx.site.id, until: until, step_up_id: bg.id},
                 opts
               )

      lock =
        Sites.create_advisory_lock!(%{site_id: ctx.site.id, reason: "x", source: "manual"}, opts)

      assert rejected?(Sites.lift_advisory_lock(lock, opts), :required)

      {_, lift} =
        step_up!(ctx.admin, auth, :lift_lock, lock.id, %{id: lock.id}, tenant: ctx.tenant)

      assert {:ok, %{lifted_at: %DateTime{}}} =
               Sites.lift_advisory_lock(lock, %{step_up_id: lift.id}, opts)
    end

    test "locking needs no step-up", ctx do
      assert {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "closing is always allowed")
    end

    test "unlock consumes one step-up for all manual locks", ctx do
      {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "a")
      {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "b")

      assert rejected?(Access.unlock(ctx.site.id, ctx.admin, nil), :required)

      {_, step_up} =
        step_up!(
          ctx.admin,
          ctx.authenticator,
          :lift_lock,
          ctx.site.id,
          Access.step_up_params(ctx.site.id, :unlock),
          tenant: ctx.tenant
        )

      assert {:ok, %{locks: [_, _]}} = Access.unlock(ctx.site.id, ctx.admin, step_up.id)
      assert reload(step_up).consumed_at

      {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "c")
      assert rejected?(Access.unlock(ctx.site.id, ctx.admin, step_up.id), :already_used)
    end

    test "a consumed step-up passed in context is checked", ctx do
      opts = [actor: ctx.admin, tenant: ctx.tenant]

      lock =
        Sites.create_advisory_lock!(%{site_id: ctx.site.id, reason: "x", source: "manual"}, opts)

      other_site = site!(ctx.tenant, ctx.admin)

      # consumed, but for another site
      consumed =
        verified_step_up!(ctx.admin, :lift_lock, other_site.id, %{}, tenant: ctx.tenant)
        |> Ash.Seed.update!(%{consumed_at: DateTime.utc_now()})

      assert rejected?(
               Sites.lift_advisory_lock(lock, Keyword.put(opts, :context, %{step_up: consumed})),
               :wrong_subject
             )

      # not consumed at all
      fresh = verified_step_up!(ctx.admin, :lift_lock, ctx.site.id, %{}, tenant: ctx.tenant)

      assert rejected?(
               Sites.lift_advisory_lock(lock, Keyword.put(opts, :context, %{step_up: fresh})),
               :not_verified
             )

      # a struct built in memory that claims to be consumed: the row says otherwise
      forged = %{fresh | consumed_at: DateTime.utc_now()}

      assert rejected?(
               Sites.lift_advisory_lock(lock, Keyword.put(opts, :context, %{step_up: forged})),
               :not_verified
             )

      # a struct for a row that does not exist
      ghost = %{forged | id: Ecto.UUID.generate()}

      assert rejected?(
               Sites.lift_advisory_lock(lock, Keyword.put(opts, :context, %{step_up: ghost})),
               :not_found
             )

      # consumed for this site, but long ago: it cannot carry over to a later operation
      stale =
        verified_step_up!(ctx.admin, :lift_lock, ctx.site.id, %{}, tenant: ctx.tenant)
        |> Ash.Seed.update!(%{consumed_at: DateTime.add(DateTime.utc_now(), -600, :second)})

      assert rejected?(
               Sites.lift_advisory_lock(lock, Keyword.put(opts, :context, %{step_up: stale})),
               :expired
             )

      assert {:ok, _} = Ash.get(Cloud.Sites.AdvisoryLock, lock.id, opts)
      refute Ash.get!(Cloud.Sites.AdvisoryLock, lock.id, opts).lifted_at
    end
  end

  test "payload hashes ignore key types, nils and datetime precision" do
    at = ~U[2030-01-01 00:00:00Z]

    assert StepUps.payload_hash(%{site_id: "a", until: at, gone: nil}) ==
             StepUps.payload_hash(%{
               "site_id" => "a",
               "until" => DateTime.add(at, 0, :microsecond)
             })

    refute StepUps.payload_hash(%{minutes: 15}) == StepUps.payload_hash(%{minutes: 16})
  end
end
