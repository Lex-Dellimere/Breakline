defmodule Gateway.Enroll do
  @moduledoc """
  Enrols this box with the cloud for one site, with a one-time code an admin
  got from the site page.

      sudo breakline-gateway enroll https://gw.example.com:4011 ABCD-...-WXYZ --ca-sha256 <hex>

  which the package wraps as

      BREAKLINE_ENROLL_URL=... BREAKLINE_ENROLL_CODE=... BREAKLINE_ENROLL_CA_SHA256=... \\
        BREAKLINE_DATA_DIR=/var/lib/breakline \\
        /opt/breakline-gateway/bin/gateway eval 'Gateway.Enroll.run_from_env()'

  ## Identity

  The box's identity is an EC P-256 key and a long-lived self-signed
  certificate (`Breakline.GatewayIdentity`) in `<data_dir>/identity/`:
  `gateway_cert.pem` and `gateway_key.pem` (mode 0600, directory 0700). They
  are made on the first enrolment and kept after that, so enrolling the same
  box again keeps its key. No CA signs the certificate: the cloud pins its
  sha256 on the site.

  ## Handshake

  The box opens a TLS session to the url with its certificate. It has no CA
  file yet, so it trusts the server chain only through the pinned CA: the
  `--ca-sha256` value is the sha256 of the CA certificate's DER-encoded
  SubjectPublicKeyInfo (as kubeadm's discovery hash), and the chain the
  server sends must contain a certificate with that key. The server
  certificate must then verify against it and carry the url's host name.
  Over that session it posts `{"code": ...}` to `/gateway/enroll`. The cloud
  pins the certificate of this session (the handshake proved the box holds
  its key) and answers the site id, the signer public keys, the CA pem, the
  uplink url and the server name. The CA pem must hash to the pin as well.

  ## Result

  `<data_dir>/enrollment.json` (site id, public keys, uplink url, server name,
  cloud url, fingerprint, time) and `<data_dir>/server_ca.pem`, both written
  atomically. `config/runtime.exs` reads them, with the identity, at the next
  boot for whatever the `BREAKLINE_*` environment variables do not set. The
  gateway has to be restarted to use a new enrolment.
  """

  require Logger

  alias Breakline.GatewayIdentity

  @timeout 15_000
  @max_response 64 * 1024

  @type paths :: %{
          identity_dir: Path.t(),
          cert: Path.t(),
          key: Path.t(),
          enrollment: Path.t(),
          ca: Path.t()
        }

  @doc "Where the identity and the enrolment live under `data_dir`."
  @spec paths(Path.t()) :: paths()
  def paths(data_dir) do
    identity = Path.join(data_dir, "identity")

    %{
      identity_dir: identity,
      cert: Path.join(identity, "gateway_cert.pem"),
      key: Path.join(identity, "gateway_key.pem"),
      enrollment: Path.join(data_dir, "enrollment.json"),
      ca: Path.join(data_dir, "server_ca.pem")
    }
  end

  @doc """
  The box's identity in `data_dir`: read back when it is there, made and
  written when it is not. An identity that is there but unreadable or does
  not match its key is an error, never silently replaced.
  """
  @spec ensure_identity(Path.t()) :: {:ok, GatewayIdentity.t()} | {:error, term()}
  def ensure_identity(data_dir) do
    p = paths(data_dir)

    case {File.read(p.cert), File.read(p.key)} do
      {{:ok, cert}, {:ok, key}} ->
        GatewayIdentity.from_pem(cert, key)

      {{:error, :enoent}, {:error, :enoent}} ->
        create_identity(p)

      _ ->
        {:error, {:incomplete_identity, p.identity_dir}}
    end
  end

  @doc """
  Enrols: makes or reads the identity, runs the handshake with `url`,
  `code` and the CA pin `ca_sha256` (64 hex characters), and writes the
  enrolment to `data_dir`. Returns `{:ok, enrollment}` (the map written to
  `enrollment.json`) or `{:error, reason}`; on an error the enrolment is not
  written (the identity, once made, is kept).

  Options: `:timeout` (ms, default 15 s) for connecting and for the answer.
  """
  @spec run(String.t(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(url, code, ca_sha256, data_dir, opts \\ []) do
    with {:ok, target} <- parse_url(url),
         {:ok, pin} <- parse_pin(ca_sha256),
         :ok <- check_code(code),
         {:ok, identity} <- ensure_identity(data_dir),
         {:ok, answer} <- handshake(target, pin, identity, code, opts),
         {:ok, enrollment, ca_pem} <- check_answer(answer, pin, url, identity) do
      write_enrollment(paths(data_dir), enrollment, ca_pem)
    end
  end

  @doc """
  `run/5` with its arguments from the environment (`BREAKLINE_ENROLL_URL`,
  `BREAKLINE_ENROLL_CODE`, `BREAKLINE_ENROLL_CA_SHA256`, `BREAKLINE_DATA_DIR`,
  default `/var/lib/breakline`), for `bin/gateway eval`. Starts what it needs
  (the apps are not started under `eval`), prints one line, and halts with 0
  on success and 1 on failure.
  """
  @spec run_from_env() :: no_return()
  def run_from_env do
    case from_env(System.get_env()) do
      {:ok, line} ->
        IO.puts(line)
        System.halt(0)

      {:error, line} ->
        IO.puts(:stderr, line)
        System.halt(1)
    end
  end

  @doc """
  The body of `run_from_env/0` for an environment map, without printing or
  halting. Returns `{:ok, line}` or `{:error, line}`.
  """
  @spec from_env(%{String.t() => String.t()}) :: {:ok, String.t()} | {:error, String.t()}
  def from_env(env) do
    missing =
      Enum.reject(
        ~w(BREAKLINE_ENROLL_URL BREAKLINE_ENROLL_CODE BREAKLINE_ENROLL_CA_SHA256),
        &(env[&1] not in [nil, ""])
      )

    with [] <- missing,
         {:ok, _} <- Application.ensure_all_started([:crypto, :public_key, :ssl]) do
      data_dir = Map.get(env, "BREAKLINE_DATA_DIR", "/var/lib/breakline")

      case run(
             env["BREAKLINE_ENROLL_URL"],
             env["BREAKLINE_ENROLL_CODE"],
             env["BREAKLINE_ENROLL_CA_SHA256"],
             data_dir
           ) do
        {:ok, e} ->
          {:ok,
           "enrolled: site #{e["site_id"]}, gateway certificate #{e["fingerprint"]}, " <>
             "settings in #{paths(data_dir).enrollment}; restart the gateway to connect"}

        {:error, reason} ->
          {:error, "enrolment failed: " <> format_error(reason)}
      end
    else
      names when is_list(names) -> {:error, "enrolment failed: #{Enum.join(names, ", ")} not set"}
      {:error, reason} -> {:error, "enrolment failed: could not start tls: #{inspect(reason)}"}
    end
  end

  @doc """
  The enrolment saved in `data_dir`, as written by `run/5`, or `:error` when
  there is none or it is unreadable.
  """
  @spec read(Path.t()) :: {:ok, map()} | :error
  def read(data_dir) do
    with {:ok, bytes} <- File.read(paths(data_dir).enrollment),
         {:ok, %{"site_id" => id} = e} when is_binary(id) and id != "" <- JSON.decode(bytes) do
      {:ok, e}
    else
      _ -> :error
    end
  end

  @doc "A readable sentence for an enrolment error."
  @spec format_error(term()) :: String.t()
  def format_error(:invalid_url), do: "the url must be https://host[:port]"
  def format_error(:invalid_pin), do: "--ca-sha256 must be 64 hex characters"
  def format_error(:invalid_code), do: "the code is empty or too long"
  def format_error({:http, 403, _}), do: "the code is wrong, used, cancelled or expired"
  def format_error({:http, 409, _}), do: "another site already uses this box's certificate"
  def format_error({:http, 429, _}), do: "too many attempts from this address, wait 10 minutes"
  def format_error({:http, status, error}), do: "the cloud answered #{status} #{inspect(error)}"

  def format_error({:tls, {:tls_alert, {:unknown_ca, _}}}),
    do: "the server's certificate does not chain to the pinned ca (check --ca-sha256)"

  def format_error({:tls, {:tls_alert, {:handshake_failure, _}}}),
    do: "the tls handshake failed (wrong host name or pinned ca)"

  def format_error({:tls, {:tls_alert, {kind, _}}}), do: "the tls handshake failed: #{kind}"
  def format_error({:tls, reason}), do: "could not connect: #{inspect(reason)}"
  def format_error({:bad_answer, why}), do: "the cloud's answer was not usable: #{why}"
  def format_error({:incomplete_identity, dir}), do: "#{dir} has a certificate or a key, not both"
  def format_error(:invalid_identity), do: "the identity in the data directory is unreadable"
  def format_error({:write, path, reason}), do: "could not write #{path}: #{inspect(reason)}"
  def format_error(reason), do: inspect(reason)

  @doc """
  The `:ssl` options for a session that trusts the server only through the
  CA pin: no CA file, a `partial_chain` that accepts the certificate in the
  server's chain whose SubjectPublicKeyInfo hashes to `pin`, and the https
  host name check for `host`.
  """
  @spec pinned_tls_opts(String.t(), String.t(), GatewayIdentity.t()) :: keyword()
  def pinned_tls_opts(host, pin, identity) do
    [
      cert: identity.cert_der,
      key: {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, identity.key)},
      verify: :verify_peer,
      cacerts: [],
      partial_chain: fn chain ->
        case Enum.find(chain, &(GatewayIdentity.spki_sha256(&1) == pin)) do
          nil -> :unknown_ca
          der -> {:trusted_ca, der}
        end
      end,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.3", :"tlsv1.2"],
      depth: 4,
      active: false,
      mode: :binary
    ]
  end

  # input

  defp parse_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: port} when is_binary(host) and host != "" ->
        {:ok, %{host: host, port: port}}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp parse_url(_url), do: {:error, :invalid_url}

  defp parse_pin(pin) when is_binary(pin) do
    pin = pin |> String.trim() |> String.downcase() |> String.replace_prefix("sha256:", "")
    if pin =~ ~r/^[0-9a-f]{64}$/, do: {:ok, pin}, else: {:error, :invalid_pin}
  end

  defp parse_pin(_pin), do: {:error, :invalid_pin}

  defp check_code(code) when is_binary(code) and byte_size(code) in 1..200, do: :ok
  defp check_code(_code), do: {:error, :invalid_code}

  # identity

  defp create_identity(p) do
    identity = GatewayIdentity.new("breakline-gateway")

    with :ok <- File.mkdir_p(p.identity_dir),
         :ok <- File.chmod(p.identity_dir, 0o700),
         # restrict the key file before the key goes in
         :ok <- atomic_write(p.key, GatewayIdentity.key_pem(identity), 0o600),
         :ok <- atomic_write(p.cert, GatewayIdentity.cert_pem(identity), 0o644) do
      {:ok, identity}
    else
      {:error, {:write, _path, _reason} = error} -> {:error, error}
      {:error, reason} -> {:error, {:write, p.identity_dir, reason}}
    end
  end

  # handshake

  defp handshake(target, pin, identity, code, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    tls = pinned_tls_opts(target.host, pin, identity)

    case :ssl.connect(String.to_charlist(target.host), target.port, tls, timeout) do
      {:ok, socket} ->
        try do
          post(socket, target, code, timeout)
        after
          :ssl.close(socket)
        end

      {:error, reason} ->
        {:error, {:tls, reason}}
    end
  end

  defp post(socket, target, code, timeout) do
    body = JSON.encode!(%{"code" => code})

    request = [
      "POST /gateway/enroll HTTP/1.1\r\n",
      "host: #{target.host}:#{target.port}\r\n",
      "content-type: application/json\r\n",
      "accept: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]

    with :ok <- :ssl.send(socket, request),
         {:ok, raw} <- recv_all(socket, "", timeout) do
      parse_response(raw)
    else
      {:error, reason} -> {:error, {:tls, reason}}
    end
  end

  defp recv_all(socket, acc, timeout) do
    case :ssl.recv(socket, 0, timeout) do
      {:ok, data} when byte_size(acc) + byte_size(data) <= @max_response ->
        recv_all(socket, acc <> data, timeout)

      {:ok, _data} ->
        {:error, :response_too_large}

      {:error, :closed} when acc != "" ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(raw) do
    with [head, rest] <- :binary.split(raw, "\r\n\r\n"),
         ["HTTP/1.1 " <> status_line | header_lines] <- String.split(head, "\r\n"),
         {status, _} <- Integer.parse(status_line) do
      headers =
        Map.new(header_lines, fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(String.trim(name)), String.trim(value)}
        end)

      body =
        case Integer.parse(headers["content-length"] || "") do
          {length, ""} when length <= byte_size(rest) -> binary_part(rest, 0, length)
          _ -> rest
        end

      case {status, JSON.decode(body)} do
        {200, {:ok, %{} = answer}} -> {:ok, answer}
        {status, {:ok, %{"error" => error}}} -> {:error, {:http, status, error}}
        {status, _} -> {:error, {:http, status, nil}}
      end
    else
      _ -> {:error, {:bad_answer, "not an http response"}}
    end
  end

  # the answer

  defp check_answer(answer, pin, url, identity) do
    with {:ok, site_id} <- string(answer, "site_id"),
         {:ok, keys} <- public_keys(answer["public_keys"]),
         {:ok, uplink_url} <- string(answer, "uplink_url"),
         true <- String.starts_with?(uplink_url, "wss://") || {:bad, "uplink_url is not wss://"},
         {:ok, server_name} <- string(answer, "server_name"),
         {:ok, ca_pem} <- ca_pem(answer["ca_pem"], pin) do
      enrollment = %{
        "site_id" => site_id,
        "public_keys" => keys,
        "uplink_url" => uplink_url,
        "server_name" => server_name,
        "cloud_url" => url,
        "fingerprint" => GatewayIdentity.fingerprint(identity),
        "enrolled_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      {:ok, enrollment, ca_pem}
    else
      {:bad, why} -> {:error, {:bad_answer, why}}
    end
  end

  defp string(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:bad, "#{key} is missing"}
    end
  end

  defp public_keys(keys) when is_map(keys) and map_size(keys) > 0 do
    if Enum.all?(keys, fn {id, key} -> is_binary(id) and id != "" and valid_key?(key) end),
      do: {:ok, keys},
      else: {:bad, "public_keys are not 32 byte base64url keys"}
  end

  defp public_keys(_keys), do: {:bad, "public_keys are missing"}

  defp valid_key?(key) when is_binary(key),
    do: match?({:ok, <<_::binary-size(32)>>}, Base.url_decode64(key, padding: false))

  defp valid_key?(_key), do: false

  # the ca the cloud hands over must be the one the session was pinned to
  defp ca_pem(pem, pin) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _}] ->
        if GatewayIdentity.spki_sha256(der) == pin,
          do: {:ok, GatewayIdentity.cert_pem(der)},
          else: {:bad, "ca_pem does not match --ca-sha256"}

      _ ->
        {:bad, "ca_pem is not one certificate"}
    end
  rescue
    _ -> {:bad, "ca_pem is not a certificate"}
  end

  defp ca_pem(_pem, _pin), do: {:bad, "ca_pem is missing"}

  # writing

  defp write_enrollment(p, enrollment, ca_pem) do
    with :ok <- atomic_write(p.ca, ca_pem, 0o644),
         :ok <- atomic_write(p.enrollment, JSON.encode!(enrollment) <> "\n", 0o644) do
      {:ok, enrollment}
    end
  end

  # tmp file, fsync, rename, so a power cut leaves the old file or the new one
  defp atomic_write(path, data, mode) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, mode),
         {:ok, io} <- File.open(tmp, [:write, :binary, :raw]),
         :ok <- write_sync(io, data),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write, path, reason}}
    end
  end

  defp write_sync(io, data) do
    with :ok <- :file.write(io, data),
         :ok <- :file.sync(io) do
      :file.close(io)
    else
      error ->
        :file.close(io)
        error
    end
  end
end
