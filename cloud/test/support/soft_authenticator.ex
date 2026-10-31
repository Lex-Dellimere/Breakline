defmodule Cloud.SoftAuthenticator do
  @moduledoc """
  A software WebAuthn authenticator for tests: a real ES256 (P-256) key made
  with `:crypto`, producing "none" attestations and signed assertions that
  `Wax` verifies like a browser's.

      authenticator = Cloud.SoftAuthenticator.new()
      attestation = Cloud.SoftAuthenticator.attest(authenticator, options)
      {authenticator, assertion} = Cloud.SoftAuthenticator.assert(authenticator, options)

  `options` are the json maps the server pushes to the browser hook
  (`Cloud.Accounts.Passkeys.registration_options/1`,
  `Cloud.Accounts.StepUps.request_options/2`). The outputs are the maps the
  hook pushes back, base64url encoded.

  Overrides for negative tests: `origin:`, `rp_id:`, `sign_count:`,
  `user_verified: false`, `challenge:` and `tamper_signature: true`.
  """

  import Bitwise

  defstruct [:credential_id, :public, :private, sign_count: 0]

  @flag_up 0x01
  @flag_uv 0x04
  @flag_at 0x40

  def new(opts \\ []) do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)

    %__MODULE__{
      credential_id:
        Keyword.get_lazy(opts, :credential_id, fn -> :crypto.strong_rand_bytes(32) end),
      public: public,
      private: private,
      sign_count: Keyword.get(opts, :sign_count, 0)
    }
  end

  @doc "The COSE key map of the authenticator's public key."
  def cose_key(%__MODULE__{public: <<4, x::binary-size(32), y::binary-size(32)>>}) do
    %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
  end

  @doc "A registration response for `navigator.credentials.create` options."
  def attest(%__MODULE__{} = authenticator, options, overrides \\ []) do
    rp_id = Keyword.get(overrides, :rp_id, get(options, [:rp, :id]))
    challenge = Keyword.get(overrides, :challenge, get(options, [:challenge]))
    client_data = client_data("webauthn.create", challenge, overrides)

    cose =
      authenticator
      |> cose_key()
      |> Map.new(fn
        {k, v} when is_binary(v) -> {k, %CBOR.Tag{tag: :bytes, value: v}}
        pair -> pair
      end)
      |> CBOR.encode()
      |> IO.iodata_to_binary()

    attested =
      <<0::128, byte_size(authenticator.credential_id)::16, authenticator.credential_id::binary,
        cose::binary>>

    auth_data =
      auth_data(rp_id, flags(overrides) ||| @flag_at, authenticator.sign_count) <> attested

    attestation_object =
      %{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      }
      |> CBOR.encode()
      |> IO.iodata_to_binary()

    %{
      "raw_id" => b64(authenticator.credential_id),
      "attestation_object" => b64(attestation_object),
      "client_data_json" => b64(client_data)
    }
  end

  @doc """
  An assertion for `navigator.credentials.get` options. Returns the
  authenticator with its counter moved on, and the assertion.
  """
  def assert(%__MODULE__{} = authenticator, options, overrides \\ []) do
    sign_count = Keyword.get(overrides, :sign_count, authenticator.sign_count + 1)
    rp_id = Keyword.get(overrides, :rp_id, get(options, [:rp_id]))
    challenge = Keyword.get(overrides, :challenge, get(options, [:challenge]))
    client_data = client_data("webauthn.get", challenge, overrides)
    auth_data = auth_data(rp_id, flags(overrides), sign_count)

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data),
        [authenticator.private, :secp256r1]
      )

    signature =
      if overrides[:tamper_signature] do
        :crypto.sign(:ecdsa, :sha256, "something else", [authenticator.private, :secp256r1])
      else
        signature
      end

    assertion = %{
      "raw_id" => b64(authenticator.credential_id),
      "authenticator_data" => b64(auth_data),
      "signature" => b64(signature),
      "client_data_json" => b64(client_data),
      "user_handle" => nil
    }

    {%{authenticator | sign_count: sign_count}, assertion}
  end

  defp flags(overrides) do
    if Keyword.get(overrides, :user_verified, true), do: @flag_up ||| @flag_uv, else: @flag_up
  end

  defp auth_data(rp_id, flags, sign_count) do
    :crypto.hash(:sha256, rp_id) <> <<flags::8, sign_count::32>>
  end

  defp client_data(type, challenge, overrides) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => challenge,
      "origin" => Keyword.get(overrides, :origin, Cloud.WebAuthn.origin()),
      "crossOrigin" => false
    })
  end

  # the options may come with atom keys (built on the server) or string keys (json)
  defp get(map, [key]), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get(map, [key | rest]), do: get(get(map, [key]), rest)

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
