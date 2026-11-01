defmodule Breakline.GatewayIdentityTest do
  use ExUnit.Case, async: true

  alias Breakline.GatewayIdentity

  @moduletag :tmp_dir

  test "makes a self-signed p-256 client certificate that openssl accepts", %{tmp_dir: dir} do
    id = GatewayIdentity.new("gateway-1")
    path = Path.join(dir, "gw.pem")
    File.write!(path, GatewayIdentity.cert_pem(id))

    {:OTPCertificate, tbs, {:SignatureAlgorithm, sig_alg, _}, _} =
      :public_key.pkix_decode_cert(id.cert_der, :otp)

    assert sig_alg == {1, 2, 840, 10045, 4, 3, 2}
    assert :public_key.pkix_is_self_signed(id.cert_der)
    assert {:ok, _} = :public_key.pkix_path_validation(id.cert_der, [id.cert_der], [])
    assert {:OTPTBSCertificate, :v3, serial, _, _, _, _, _, _, _, _} = tbs
    assert serial > 0

    if openssl = System.find_executable("openssl") do
      assert {out, 0} = System.cmd(openssl, ["x509", "-in", path, "-noout", "-text"])
      assert out =~ "Subject: CN=gateway-1"
      assert out =~ "Not After : Dec 31 23:59:59 9999 GMT"
      assert out =~ "TLS Web Client Authentication"
      assert out =~ "NIST CURVE: P-256"
      assert {_, 0} = System.cmd(openssl, ["verify", "-CAfile", path, path])
    end
  end

  test "round-trips through pem and refuses a key of another certificate" do
    a = GatewayIdentity.new("a")
    b = GatewayIdentity.new("b")

    assert {:ok, ^a} =
             GatewayIdentity.from_pem(GatewayIdentity.cert_pem(a), GatewayIdentity.key_pem(a))

    assert {:error, :invalid_identity} =
             GatewayIdentity.from_pem(GatewayIdentity.cert_pem(a), GatewayIdentity.key_pem(b))

    assert {:error, :invalid_identity} = GatewayIdentity.from_pem("", "")
    assert {:error, :invalid_identity} = GatewayIdentity.from_pem("garbage", "garbage")
  end

  test "fingerprints the der and hashes the subject public key info" do
    id = GatewayIdentity.new("a")
    fp = GatewayIdentity.fingerprint(id)
    assert fp == :crypto.hash(:sha256, id.cert_der) |> Base.encode16(case: :lower)
    assert fp =~ ~r/^[0-9a-f]{64}$/

    # a second certificate for the same key has another fingerprint but the same spki hash
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(id.cert_der, :otp)
    resigned = :public_key.pkix_sign(put_elem(tbs, 2, 42), id.key)
    assert GatewayIdentity.fingerprint(resigned) != fp
    assert GatewayIdentity.spki_sha256(resigned) == GatewayIdentity.spki_sha256(id.cert_der)

    assert GatewayIdentity.spki_sha256(id.cert_der) !=
             GatewayIdentity.spki_sha256(GatewayIdentity.new("b").cert_der)
  end

  test "takes explicit validity dates, utctime before 2050" do
    id =
      GatewayIdentity.new("old",
        not_before: ~U[2020-01-01 00:00:00Z],
        not_after: ~U[2021-01-01 00:00:00Z]
      )

    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(id.cert_der, :otp)

    assert {:Validity, {:utcTime, ~c"200101000000Z"}, {:utcTime, ~c"210101000000Z"}} =
             elem(tbs, 5)

    assert {:error, {:bad_cert, :cert_expired}} =
             :public_key.pkix_path_validation(id.cert_der, [id.cert_der], [])
  end
end
