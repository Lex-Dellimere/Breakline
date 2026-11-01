defmodule Cloud.Sites.GatewayEnrollments do
  @moduledoc """
  Codes, lookups and the enrolment answer for `Cloud.Sites.GatewayEnrollment`.

  ## Codes

  A code is 20 bytes (160 bits) from `:crypto.strong_rand_bytes/1`, shown as
  RFC 4648 base32 without padding in eight groups of four
  (`ABCD-EFGH-...`), so it can be typed from a screen. Case, spaces and
  dashes do not matter when it is typed back. Only `hash_code/1` of it, the
  lowercase hex sha256 of the 20 bytes, is stored. A code lives 30 minutes
  and is used at most once.

  ## Enrolling

  `enroll/3` is the trusted step behind `CloudWeb.GatewayEnroll`: it finds
  the code by its hash under a row lock, refuses anything that is not a
  usable code with the same `{:error, :invalid}`, pins the fingerprint of the
  certificate the gateway presented in the TLS session on the site, and
  marks the code used, all in one transaction with its audit entry.

  ## What the gateway is told

  `answer/1` is what an enrolled gateway needs to run: its site id, the
  signer public keys it must trust, the CA of the gateway endpoint's server
  certificate (pem), the uplink url and the name the server certificate
  carries. The CA pem and the urls come from config:

      config :cloud, :gateway_enrollment,
        url: "https://gw.example.com:4011",
        ca_certfile: "/etc/breakline/gateway_ca.pem",
        server_name: "gw.example.com"   # optional, defaults to the url's host

  `ca_sha256/0` is the value the gateway pins with `--ca-sha256`: the sha256
  of the CA certificate's DER-encoded SubjectPublicKeyInfo, lowercase hex,
  the same hash kubeadm's `--discovery-token-ca-cert-hash` uses.
  """

  alias Cloud.Sites
  alias Cloud.Sites.{GatewayEnrollment, Site}

  @ttl_seconds 30 * 60
  @code_bytes 20

  @doc "How long a new code is valid, in seconds."
  def ttl_seconds, do: @ttl_seconds

  @doc "A new raw code (grouped base32) and its hash: `{code, code_hash}`."
  @spec new_code() :: {String.t(), String.t()}
  def new_code do
    raw = :crypto.strong_rand_bytes(@code_bytes)

    code =
      raw
      |> Base.encode32(padding: false)
      |> String.graphemes()
      |> Enum.chunk_every(4)
      |> Enum.map_join("-", &Enum.join/1)

    {code, sha256(raw)}
  end

  @doc """
  The stored hash for a typed code. Case, spaces and dashes are ignored. A
  string that is not a well-formed code still hashes (to a value no code can
  have), so every lookup does the same work.
  """
  @spec hash_code(String.t()) :: String.t()
  def hash_code(code) when is_binary(code) do
    normalised = code |> String.upcase() |> String.replace(~r/[\s-]/, "")

    case Base.decode32(normalised, padding: false) do
      {:ok, <<_::binary-size(@code_bytes)>> = raw} -> sha256(raw)
      _ -> sha256("malformed:" <> code)
    end
  end

  @doc "Whether a code is neither used, cancelled nor expired at `now`."
  @spec usable?(GatewayEnrollment.t(), DateTime.t()) :: boolean()
  def usable?(%GatewayEnrollment{} = e, now \\ DateTime.utc_now()) do
    is_nil(e.used_at) and is_nil(e.cancelled_at) and DateTime.compare(e.expires_at, now) == :gt
  end

  @doc """
  Issues a code for `site` as `actor`, consuming the verified `:enroll_gateway`
  step-up `step_up_id`. The raw code is in the record's `:code` metadata.
  """
  @spec issue(Site.t(), struct(), String.t() | nil) ::
          {:ok, GatewayEnrollment.t()} | {:error, term()}
  def issue(%Site{} = site, actor, step_up_id) do
    Sites.issue_gateway_enrollment(%{site_id: site.id, step_up_id: step_up_id},
      actor: actor,
      tenant: site.tenant_id
    )
  end

  @doc """
  Trusted: enrols the gateway whose certificate DER is `cert_der` with the
  typed `code`. `remote_ip` (a string) is recorded with the use.

  Returns `{:ok, %{site: site, replaced_fingerprint: fp | nil}}` with the
  site as it is pinned now, or `{:error, :invalid}` for an unknown,
  malformed, used, cancelled or expired code, or
  `{:error, :certificate_in_use}` when another site already pins the
  certificate.
  """
  @spec enroll(String.t(), binary(), String.t() | nil) ::
          {:ok, %{site: Site.t(), replaced_fingerprint: String.t() | nil}}
          | {:error, :invalid | :certificate_in_use | term()}
  def enroll(code, cert_der, remote_ip)
      when is_binary(code) and is_binary(cert_der) do
    fingerprint = Cloud.Gateways.cert_fingerprint(cert_der)

    # these resources have no notifiers, so notifications are taken and dropped
    Cloud.Repo.transaction(fn ->
      with {:ok, enrollment} <- lock(code),
           {:ok, site} <- Sites.get_site(enrollment.site_id, authorize?: false),
           :ok <- not_pinned_elsewhere(fingerprint, site),
           {:ok, _used, _} <-
             Sites.use_gateway_enrollment(
               enrollment,
               %{
                 gateway_cert_fingerprint: fingerprint,
                 replaced_fingerprint: site.gateway_cert_fingerprint,
                 remote_ip: remote_ip
               },
               tenant: enrollment.tenant_id,
               authorize?: false,
               return_notifications?: true
             ),
           {:ok, pinned, _} <-
             Sites.assign_gateway(site, fingerprint,
               authorize?: false,
               return_notifications?: true
             ) do
        %{site: pinned, replaced_fingerprint: site.gateway_cert_fingerprint}
      else
        {:error, reason} -> Cloud.Repo.rollback(reason)
      end
    end)
  end

  def enroll(_code, _cert_der, _remote_ip), do: {:error, :invalid}

  @doc """
  What the gateway of `site` is told once it enrolled: `site_id`,
  `public_keys` (key id to base64url public key), `ca_pem`, `uplink_url`
  and `server_name`.
  """
  @spec answer(Site.t()) :: map()
  def answer(%Site{} = site) do
    %{
      "site_id" => site.id,
      "public_keys" => %{
        Cloud.Signer.key_id() => Base.url_encode64(Cloud.Signer.public_key(), padding: false)
      },
      "ca_pem" => ca_pem!(),
      "uplink_url" => uplink_url(),
      "server_name" => server_name()
    }
  end

  @doc """
  The command an admin runs on the gateway box for a raw code:
  `sudo breakline-gateway enroll <url> <code> --ca-sha256 <hex>`.
  """
  @spec command(String.t()) :: String.t()
  def command(code) when is_binary(code) do
    "sudo breakline-gateway enroll #{url()} #{code} --ca-sha256 #{ca_sha256()}"
  end

  @doc "The base url gateways enrol at, for example `https://gw.example.com:4011`."
  @spec url() :: String.t()
  def url, do: Keyword.fetch!(config(), :url)

  @doc "The url of the gateway socket, `wss://<host>:<port>/gateway/socket/websocket`."
  @spec uplink_url() :: String.t()
  def uplink_url do
    uri = URI.parse(url())
    URI.to_string(%URI{uri | scheme: "wss", path: "/gateway/socket/websocket"})
  end

  @doc "The name the gateway endpoint's server certificate carries."
  @spec server_name() :: String.t()
  def server_name, do: Keyword.get(config(), :server_name) || URI.parse(url()).host

  @doc "The pem of the CA that signs the gateway endpoint's server certificate."
  @spec ca_pem!() :: String.t()
  def ca_pem! do
    [{:Certificate, der, _} | _] = ca_entries!()
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  @doc """
  The `--ca-sha256` pin: the sha256 of the CA certificate's DER-encoded
  SubjectPublicKeyInfo, lowercase hex.
  """
  @spec ca_sha256() :: String.t()
  def ca_sha256 do
    [{:Certificate, der, _} | _] = ca_entries!()
    Breakline.GatewayIdentity.spki_sha256(der)
  end

  @doc "Whether enrolment is configured (a url and a readable CA certificate)."
  @spec configured?() :: boolean()
  def configured? do
    is_binary(config()[:url]) and match?([{:Certificate, _, _} | _], ca_entries())
  end

  defp ca_entries! do
    case ca_entries() do
      [{:Certificate, _, _} | _] = entries -> entries
      _ -> raise "no gateway ca certificate configured (config :cloud, :gateway_enrollment)"
    end
  end

  defp ca_entries do
    with path when is_binary(path) <- config()[:ca_certfile],
         {:ok, pem} <- File.read(path) do
      pem |> :public_key.pem_decode() |> Enum.filter(&match?({:Certificate, _, _}, &1))
    else
      _ -> []
    end
  end

  defp config, do: Application.get_env(:cloud, :gateway_enrollment, [])

  defp lock(code) do
    case Sites.lock_gateway_enrollment_by_code_hash(hash_code(code),
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %GatewayEnrollment{} = enrollment} ->
        if usable?(enrollment), do: {:ok, enrollment}, else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  defp not_pinned_elsewhere(fingerprint, site) do
    case Sites.get_site_by_gateway_fingerprint(fingerprint,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %Site{id: id}} when id != site.id -> {:error, :certificate_in_use}
      _ -> :ok
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
