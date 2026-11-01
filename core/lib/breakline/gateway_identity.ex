defmodule Breakline.GatewayIdentity do
  @moduledoc """
  A gateway's TLS identity: an EC P-256 key and a self-signed X.509
  certificate, built with OTP's `:public_key` and `:crypto` only.

  No CA signs a gateway certificate. The cloud pins the sha256 of the
  certificate DER on the gateway's site when the box enrols (`fingerprint/1`),
  and the TLS handshake proves the box holds the key. The certificate is
  long-lived (by default until 9999-12-31 23:59:59 UTC, the RFC 5280 value
  for "no well-defined expiration"): a box is retired by enrolling its
  replacement, which moves the pin, not by expiry.

  The certificate has the subject and issuer `CN=<common_name>`, a random
  127-bit serial, `basicConstraints` CA:FALSE (critical), `keyUsage`
  digitalSignature (critical), `extendedKeyUsage` clientAuth, and is signed
  with ecdsa-with-SHA256.

  `spki_sha256/1` is the CA pin a box uses to trust the cloud's gateway
  endpoint before it has the CA file: the sha256 of a certificate's
  DER-encoded SubjectPublicKeyInfo, as kubeadm's discovery hash.
  """

  require Record

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  @no_expiry ~U[9999-12-31 23:59:59Z]

  @oid_cn {2, 5, 4, 3}
  @oid_ec_public_key {1, 2, 840, 10045, 2, 1}
  @oid_ecdsa_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @oid_basic_constraints {2, 5, 29, 19}
  @oid_key_usage {2, 5, 29, 15}
  @oid_ext_key_usage {2, 5, 29, 37}
  @oid_client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}

  @type t :: %{cert_der: binary(), key: tuple()}

  @doc """
  A new key and self-signed certificate for `common_name`.

  Options: `:not_before` (default one hour ago, for clock skew) and
  `:not_after` (default 9999-12-31 23:59:59 UTC), both `DateTime`s.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(common_name, opts \\ []) when is_binary(common_name) do
    not_before =
      Keyword.get_lazy(opts, :not_before, fn ->
        DateTime.utc_now() |> DateTime.add(-3600, :second)
      end)

    not_after = Keyword.get(opts, :not_after, @no_expiry)

    key = :public_key.generate_key({:namedCurve, :secp256r1})
    {:ECPrivateKey, _version, _private, params, public, _attributes} = key
    name = {:rdnSequence, [[{:AttributeTypeAndValue, @oid_cn, {:utf8String, common_name}}]]}

    cert =
      tbs(
        version: :v3,
        serialNumber: serial(),
        signature: {:SignatureAlgorithm, @oid_ecdsa_sha256, :asn1_NOVALUE},
        issuer: name,
        validity: {:Validity, asn1_time(not_before), asn1_time(not_after)},
        subject: name,
        subjectPublicKeyInfo:
          {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @oid_ec_public_key, params},
           {:ECPoint, public}},
        extensions: [
          extension(
            extnID: @oid_basic_constraints,
            critical: true,
            extnValue: {:BasicConstraints, false, :asn1_NOVALUE}
          ),
          extension(extnID: @oid_key_usage, critical: true, extnValue: [:digitalSignature]),
          extension(extnID: @oid_ext_key_usage, critical: false, extnValue: [@oid_client_auth])
        ]
      )

    %{cert_der: :public_key.pkix_sign(cert, key), key: key}
  end

  @doc "The certificate as pem."
  @spec cert_pem(t() | binary()) :: String.t()
  def cert_pem(%{cert_der: der}), do: cert_pem(der)

  def cert_pem(der) when is_binary(der),
    do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  @doc "The private key as pem (SEC 1, `EC PRIVATE KEY`)."
  @spec key_pem(t()) :: String.t()
  def key_pem(%{key: key}),
    do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

  @doc """
  Reads an identity back from its certificate and key pem. Returns
  `{:ok, identity}` or `{:error, :invalid_identity}` when either is missing,
  malformed or the key does not belong to the certificate.
  """
  @spec from_pem(String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_identity}
  def from_pem(cert_pem, key_pem) when is_binary(cert_pem) and is_binary(key_pem) do
    with [{:Certificate, der, _} | _] <- :public_key.pem_decode(cert_pem),
         [{:ECPrivateKey, _, _} = entry | _] <- :public_key.pem_decode(key_pem),
         {:ECPrivateKey, _, _, _, public, _} = key <- :public_key.pem_entry_decode(entry),
         {:ECPoint, ^public} <- cert_public_key(der) do
      {:ok, %{cert_der: der, key: key}}
    else
      _ -> {:error, :invalid_identity}
    end
  rescue
    _ -> {:error, :invalid_identity}
  end

  @doc """
  The fingerprint the cloud pins: the sha256 of the certificate DER,
  lowercase hex.
  """
  @spec fingerprint(t() | binary()) :: String.t()
  def fingerprint(%{cert_der: der}), do: fingerprint(der)
  def fingerprint(der) when is_binary(der), do: hex_sha256(der)

  @doc """
  The sha256 of a certificate's DER-encoded SubjectPublicKeyInfo, lowercase
  hex. This is the `--ca-sha256` pin of the cloud's gateway CA.
  """
  @spec spki_sha256(binary()) :: String.t()
  def spki_sha256(cert_der) when is_binary(cert_der) do
    {:Certificate, tbs, _alg, _sig} = :public_key.der_decode(:Certificate, cert_der)
    # TBSCertificate: version, serial, signature, issuer, validity, subject, spki, ...
    spki = elem(tbs, 7)
    hex_sha256(:public_key.der_encode(:SubjectPublicKeyInfo, spki))
  end

  defp cert_public_key(der) do
    {:OTPCertificate, otp_tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    {:OTPSubjectPublicKeyInfo, _alg, point} = tbs(otp_tbs, :subjectPublicKeyInfo)
    point
  end

  # a positive serial that fits in 127 bits, so it is never encoded negative
  defp serial do
    <<_::1, n::127>> = :crypto.strong_rand_bytes(16)
    max(n, 1)
  end

  # rfc 5280: utctime through 2049, generalizedtime from 2050
  defp asn1_time(%DateTime{} = dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")

    if dt.year < 2050,
      do: {:utcTime, dt |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()},
      else: {:generalTime, dt |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}
  end

  defp hex_sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
