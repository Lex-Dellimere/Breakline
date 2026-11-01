defmodule CloudWeb.GatewayTLS do
  @moduledoc """
  The TLS options of `CloudWeb.GatewayEndpoint`'s listener.

  Gateways present self-signed client certificates (`Gateway.Enroll` makes
  one per box). No CA signs them: a gateway's identity is the sha256 of its
  certificate DER, pinned on its site at enrolment (D25). So the listener
  asks for a client certificate (`verify_peer`, `fail_if_no_peer_cert`) and
  `verify_client/3` accepts a self-signed one. The TLS handshake still checks
  the certificate's own signature and validity dates, and its
  CertificateVerify proves the client holds the private key. What a
  certificate may do is decided after the handshake: `CloudWeb.GatewaySocket`
  admits only pinned ones, and an unpinned one can only enrol
  (`CloudWeb.GatewayEnroll`).

  `cacertfile` is the CA of the endpoint's own server certificate. OTP sends
  it along with the server certificate, which is what lets a box pin it with
  `--ca-sha256` before it has the pem. A client certificate signed by that CA
  also passes the handshake, and still needs a pin like any other.
  """

  @doc """
  The listener's `transport_options` for Bandit's `thousand_island_options`.
  """
  @spec transport_options(Path.t()) :: keyword()
  def transport_options(cacertfile) do
    [
      cacertfile: cacertfile,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      verify_fun: {&__MODULE__.verify_client/3, nil},
      versions: [:"tlsv1.3", :"tlsv1.2"],
      depth: 4
    ]
  end

  @doc """
  An `:ssl` `verify_fun` that accepts a self-signed client certificate and
  otherwise keeps OTP's verdict: an expired or not yet valid self-signed
  certificate, a bad signature or an unknown CA still fail.
  """
  def verify_client(_cert, {:bad_cert, :selfsigned_peer}, state), do: {:valid, state}
  def verify_client(_cert, {:bad_cert, reason}, _state), do: {:fail, reason}
  def verify_client(_cert, {:extension, _}, state), do: {:unknown, state}
  def verify_client(_cert, :valid, state), do: {:valid, state}
  def verify_client(_cert, :valid_peer, state), do: {:valid, state}
end
