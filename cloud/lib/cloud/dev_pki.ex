defmodule Cloud.DevPKI do
  @moduledoc """
  A throwaway certificate authority for dev and tests, built with the `openssl`
  command line tool: a CA and a server certificate for the gateway endpoint.
  Gateway client certificates are self-signed (`self_signed_client/4`, the
  same `Breakline.GatewayIdentity` a real box makes when it enrols); the CA
  can still sign one with `issue_client/5`, which the endpoint accepts too.

  Every key is ECDSA P-256 and every certificate is signed with SHA-256, which TLS
  1.3 in OTP accepts. Private keys are written with mode 0600. Nothing here is fit
  for production: production certificates come from a real CA and are configured
  through `config/runtime.exs`.

  The files in `dir` (`priv/keys/` in dev, git-ignored):

    * `dev_ca_cert.pem`, `dev_ca_key.pem` - the CA
    * `gateway_endpoint_cert.pem`, `gateway_endpoint_key.pem` - the server
      certificate of `CloudWeb.GatewayEndpoint`, for `localhost` and `127.0.0.1`
  """

  @ca_cert "dev_ca_cert.pem"
  @ca_key "dev_ca_key.pem"
  @server_cert "gateway_endpoint_cert.pem"
  @server_key "gateway_endpoint_key.pem"

  @doc "The paths of the CA and server files in `dir`."
  @spec paths(Path.t()) :: %{atom() => Path.t()}
  def paths(dir) do
    %{
      ca_cert: Path.join(dir, @ca_cert),
      ca_key: Path.join(dir, @ca_key),
      server_cert: Path.join(dir, @server_cert),
      server_key: Path.join(dir, @server_key)
    }
  end

  @doc """
  Creates the CA and the gateway endpoint's server certificate in `dir`. Existing
  files are kept unless `force: true`. Returns `{:ok, paths}`, or
  `{:error, :exists}` when the CA is already there.

  Options: `:force`, `:days` (validity, default 825), `:hosts` (DNS names, default
  `["localhost"]`) and `:ips` (default `["127.0.0.1"]`).
  """
  @spec generate(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(dir, opts \\ []) do
    p = paths(dir)
    days = Keyword.get(opts, :days, 825)

    if File.exists?(p.ca_cert) and not Keyword.get(opts, :force, false) do
      {:error, :exists}
    else
      File.mkdir_p!(dir)

      with :ok <- new_key(p.ca_key),
           :ok <-
             openssl(
               ~w(req -x509 -new -sha256 -key #{p.ca_key} -out #{p.ca_cert}) ++
                 ["-days", to_string(days), "-subj", "/CN=Breakline dev CA"] ++
                 ["-addext", "basicConstraints=critical,CA:TRUE"] ++
                 ["-addext", "keyUsage=critical,keyCertSign,cRLSign"]
             ),
           :ok <-
             issue(dir, "localhost", p.server_key, p.server_cert,
               days: days,
               usage: "serverAuth",
               san:
                 san(
                   Keyword.get(opts, :hosts, ["localhost"]),
                   Keyword.get(opts, :ips, ["127.0.0.1"])
                 )
             ) do
        {:ok, p}
      end
    end
  end

  @doc """
  Issues a client certificate with common name `cn` (a site id), signed by the CA
  in `ca_dir`, and writes the certificate and key to `cert_path` and `key_path`.
  Returns `{:ok, fingerprint}`: the sha256 of the certificate DER, lowercase hex,
  as `CloudWeb.GatewaySocket` computes it.
  """
  @spec issue_client(Path.t(), String.t(), Path.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def issue_client(ca_dir, cn, cert_path, key_path, opts \\ []) do
    if File.exists?(paths(ca_dir).ca_cert) do
      File.mkdir_p!(Path.dirname(cert_path))
      File.mkdir_p!(Path.dirname(key_path))

      with :ok <-
             issue(ca_dir, cn, key_path, cert_path,
               days: Keyword.get(opts, :days, 825),
               usage: "clientAuth",
               san: nil
             ) do
        pem_fingerprint(cert_path)
      end
    else
      {:error, :no_ca}
    end
  end

  @doc """
  Makes a self-signed gateway client certificate with common name `cn` (a site
  id), the way `Gateway.Enroll` does on a box, and writes the certificate and
  key (mode 0600) to `cert_path` and `key_path`. Returns `{:ok, fingerprint}`.
  Options go to `Breakline.GatewayIdentity.new/2`.
  """
  @spec self_signed_client(String.t(), Path.t(), Path.t(), keyword()) :: {:ok, String.t()}
  def self_signed_client(cn, cert_path, key_path, opts \\ []) do
    identity = Breakline.GatewayIdentity.new(cn, opts)
    File.mkdir_p!(Path.dirname(cert_path))
    File.mkdir_p!(Path.dirname(key_path))
    # restrict the file before the key goes in
    File.write!(key_path, "")
    File.chmod!(key_path, 0o600)
    File.write!(key_path, Breakline.GatewayIdentity.key_pem(identity))
    File.write!(cert_path, Breakline.GatewayIdentity.cert_pem(identity))
    {:ok, Breakline.GatewayIdentity.fingerprint(identity)}
  end

  @doc """
  The sha256 fingerprint (lowercase hex of the DER) of the first certificate in a
  pem file.
  """
  @spec pem_fingerprint(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def pem_fingerprint(path) do
    with {:ok, pem} <- File.read(path) do
      case :public_key.pem_decode(pem) do
        [{:Certificate, der, _} | _] -> {:ok, Cloud.Gateways.cert_fingerprint(der)}
        _ -> {:error, :no_certificate}
      end
    end
  end

  # a key and a csr, then the certificate signed by the ca with the given extensions
  defp issue(ca_dir, cn, key_path, cert_path, opts) do
    p = paths(ca_dir)
    csr = cert_path <> ".csr"
    ext = cert_path <> ".ext"

    extensions =
      [
        "basicConstraints=critical,CA:FALSE",
        "keyUsage=critical,digitalSignature",
        "extendedKeyUsage=#{opts[:usage]}",
        opts[:san] && "subjectAltName=#{opts[:san]}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    File.write!(ext, extensions <> "\n")

    try do
      with :ok <- new_key(key_path),
           :ok <-
             openssl(~w(req -new -sha256 -key #{key_path} -out #{csr} -subj) ++ ["/CN=" <> cn]) do
        openssl(
          ~w(x509 -req -sha256 -in #{csr} -CA #{p.ca_cert} -CAkey #{p.ca_key} -CAcreateserial) ++
            ["-out", cert_path, "-days", to_string(opts[:days]), "-extfile", ext]
        )
      end
    after
      File.rm(csr)
      File.rm(ext)
      File.rm(Path.rootname(p.ca_cert) <> ".srl")
    end
  end

  defp new_key(path) do
    # restrict the file before the key goes in
    File.write!(path, "")
    File.chmod!(path, 0o600)
    openssl(~w(genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out #{path}))
  end

  defp san(hosts, ips) do
    (Enum.map(hosts, &("DNS:" <> &1)) ++ Enum.map(ips, &("IP:" <> &1))) |> Enum.join(",")
  end

  defp openssl(args) do
    case System.find_executable("openssl") do
      nil ->
        {:error, :openssl_not_found}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, status} -> {:error, {:openssl, status, String.trim(out)}}
        end
    end
  end
end
