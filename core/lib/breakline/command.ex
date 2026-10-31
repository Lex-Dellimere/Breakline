defmodule Breakline.Command do
  @moduledoc """
  Ed25519 signed command envelopes sent from the cloud to a gateway.

  The cloud holds the private key and signs; the gateway holds only public keys and
  verifies (threat model T3). A command is bound to one site and carries a strictly
  increasing policy version, a validity period and a random nonce, so an old or
  foreign command cannot be replayed or rolled back (T4).

  ## Wire format

      %{
        "envelope" => %{
          "type" => "policy",
          "site_id" => "site-1",
          "policy_version" => 7,
          "issued_at" => "2026-10-31T09:00:00Z",
          "expires_at" => "2026-10-31T10:00:00Z",
          "nonce" => "<16 random bytes, base64url without padding>",
          "payload" => %{...},
          "key_id" => "cloud-2026-10"
        },
        "signature" => "<64 byte ed25519 signature, base64url without padding>"
      }

  The signed message is `Breakline.CanonicalJSON.encode!(envelope)`. A verifier signs
  nothing and trusts nothing it receives: it re-encodes the decoded envelope
  canonically and checks the signature over those bytes. `key_id` sits inside the
  signed envelope so keys can be rotated without an unsigned selector.

  ## Expiry

  `expires_at` governs acceptance only. A gateway that persisted an accepted policy
  keeps enforcing it after `expires_at`; it just will not accept that command again.
  Keeping the last good policy when the cloud is unreachable is the point (T7).
  """

  alias Breakline.CanonicalJSON
  alias Breakline.Command.Verifier

  @enforce_keys [:type, :site_id, :policy_version, :issued_at, :expires_at, :nonce, :payload]
  defstruct [
    :type,
    :site_id,
    :policy_version,
    :issued_at,
    :expires_at,
    :nonce,
    :payload,
    key_id: nil
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          site_id: String.t(),
          policy_version: non_neg_integer(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          nonce: String.t(),
          payload: map(),
          key_id: String.t() | nil
        }

  @type public_key :: <<_::256>>
  @type private_key :: <<_::256>>
  @type wire :: %{required(String.t()) => term()}

  @type verify_error ::
          :malformed
          | :unknown_key
          | :bad_signature
          | :wrong_site
          | :not_yet_valid
          | :expired
          | :ttl_too_long
          | :stale_version
          | :replayed_nonce

  @envelope_keys ~w(type site_id policy_version issued_at expires_at nonce payload key_id)
  @nonce_bytes 16
  @signature_bytes 64

  @doc """
  Generates an Ed25519 key pair as `{public_key, private_key}`, both 32 raw bytes.
  """
  @spec generate_keypair() :: {public_key(), private_key()}
  def generate_keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc """
  Builds an unsigned command.

  Required attributes: `:type`, `:site_id`, `:policy_version`, `:payload` (a
  json-compatible map, for example `Breakline.Policy.to_map/1`) and one of
  `:expires_at` or `:ttl_seconds`.

  Optional: `:issued_at` (defaults to now) and `:nonce` (defaults to 16 fresh random
  bytes, base64url encoded). Datetimes are shifted to UTC and truncated to seconds.
  Atom keys in the payload are normalised to strings.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Map.new(attrs)

    with {:ok, type} <- fetch_string(attrs, :type),
         {:ok, site_id} <- fetch_string(attrs, :site_id),
         {:ok, version} <- fetch_version(attrs),
         {:ok, payload} <- fetch_payload(attrs),
         {:ok, issued_at} <- fetch_issued_at(attrs),
         {:ok, expires_at} <- fetch_expires_at(attrs, issued_at),
         {:ok, nonce} <- fetch_nonce(attrs) do
      {:ok,
       %__MODULE__{
         type: type,
         site_id: site_id,
         policy_version: version,
         issued_at: issued_at,
         expires_at: expires_at,
         nonce: nonce,
         payload: payload
       }}
    end
  end

  @doc """
  Like `new/1` but raises `ArgumentError` on invalid attributes.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, command} -> command
      {:error, reason} -> raise ArgumentError, "invalid command: #{inspect(reason)}"
    end
  end

  @doc """
  Signs a command with `private_key`, recording `key_id` in the envelope, and returns
  the wire map.
  """
  @spec sign(t(), String.t(), private_key()) :: wire()
  def sign(%__MODULE__{} = command, key_id, private_key)
      when is_binary(key_id) and key_id != "" and is_binary(private_key) do
    envelope = to_envelope(%{command | key_id: key_id})
    message = CanonicalJSON.encode!(envelope)
    signature = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
    %{"envelope" => envelope, "signature" => b64(signature)}
  end

  @doc """
  Encodes a wire map to (canonical) JSON bytes for transport.
  """
  @spec encode_wire(wire()) :: binary()
  def encode_wire(wire) when is_map(wire), do: CanonicalJSON.encode!(wire)

  @doc """
  Decodes JSON bytes into a wire map. The result is not verified: pass it to `verify/3`.
  """
  @spec decode_wire(binary()) :: {:ok, wire()} | {:error, :malformed}
  def decode_wire(json) when is_binary(json) do
    case CanonicalJSON.decode(json) do
      {:ok, wire} when is_map(wire) -> {:ok, wire}
      _ -> {:error, :malformed}
    end
  end

  @doc """
  Verifies a received command (wire map or JSON bytes) against `verifier` at `now`.

  Checks run in this order and the first failure is returned:

    1. `:malformed`: wrong shape or types, non-canonical datetimes, nonce or signature,
       or `expires_at` not after `issued_at`
    2. `:unknown_key`: `key_id` is not in `verifier.public_keys`
    3. `:bad_signature`: the signature does not match the canonical envelope
    4. `:wrong_site`: the command is for another site
    5. `:not_yet_valid`: `issued_at` is more than `max_skew_seconds` in the future
    6. `:expired`: `now >= expires_at`
    7. `:ttl_too_long`: `expires_at - issued_at > max_ttl_seconds`
    8. `:stale_version`: `policy_version <= last_version`
    9. `:replayed_nonce`: the nonce was already accepted and has not expired

  On success the returned verifier has `last_version` set to the command's version and
  its nonce recorded; nonces whose `expires_at` has passed are pruned. The caller must
  persist the new verifier state before acting on the command.
  """
  @spec verify(wire() | binary(), Verifier.t(), DateTime.t()) ::
          {:ok, t(), Verifier.t()} | {:error, verify_error()}
  def verify(json, %Verifier{} = verifier, %DateTime{} = now) when is_binary(json) do
    with {:ok, wire} <- decode_wire(json), do: verify(wire, verifier, now)
  end

  def verify(wire, %Verifier{} = verifier, %DateTime{} = now) when is_map(wire) do
    with {:ok, command} <- authenticate(wire, verifier),
         :ok <- check_not_yet_valid(command, verifier, now),
         :ok <- check_expired(command, now),
         :ok <- check_ttl(command, verifier),
         :ok <- check_version(command, verifier),
         verifier = Verifier.prune(verifier, now),
         :ok <- check_nonce(command, verifier) do
      verifier = %{
        verifier
        | last_version: command.policy_version,
          seen_nonces: Map.put(verifier.seen_nonces, command.nonce, command.expires_at)
      }

      {:ok, command, verifier}
    end
  end

  def verify(_wire, %Verifier{}, %DateTime{}), do: {:error, :malformed}

  @doc """
  Checks that a command (wire map or JSON bytes) is well formed, signed by a key in
  `verifier.public_keys` and addressed to `verifier.site_id`.

  These are the first four checks of `verify/3` (`:malformed`, `:unknown_key`,
  `:bad_signature`, `:wrong_site`), with no time, version or nonce checks and no
  verifier update. It is for re-checking a command the gateway accepted earlier and
  persisted, for example at boot after the command has expired: expiry governs
  acceptance only, so an accepted policy keeps being enforced. Never use it to accept
  a new command.
  """
  @spec authenticate(wire() | binary(), Verifier.t()) ::
          {:ok, t()} | {:error, :malformed | :unknown_key | :bad_signature | :wrong_site}
  def authenticate(json, %Verifier{} = verifier) when is_binary(json) do
    with {:ok, wire} <- decode_wire(json), do: authenticate(wire, verifier)
  end

  def authenticate(wire, %Verifier{} = verifier) when is_map(wire) do
    with {:ok, command, envelope, signature} <- parse(wire),
         {:ok, public_key} <- lookup_key(verifier, command.key_id),
         :ok <- check_signature(envelope, signature, public_key),
         :ok <- check_site(command, verifier) do
      {:ok, command}
    end
  end

  def authenticate(_wire, %Verifier{}), do: {:error, :malformed}

  # building

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, v} when is_binary(v) and v != "" ->
        if String.valid?(v), do: {:ok, v}, else: {:error, {:invalid, key}}

      {:ok, _} ->
        {:error, {:invalid, key}}

      :error ->
        {:error, {:missing, key}}
    end
  end

  defp fetch_version(attrs) do
    case Map.fetch(attrs, :policy_version) do
      {:ok, v} when is_integer(v) and v >= 0 -> {:ok, v}
      {:ok, _} -> {:error, {:invalid, :policy_version}}
      :error -> {:error, {:missing, :policy_version}}
    end
  end

  defp fetch_payload(attrs) do
    with {:ok, payload} when is_map(payload) and not is_struct(payload) <-
           Map.fetch(attrs, :payload),
         {:ok, json} <- CanonicalJSON.encode(payload) do
      # round trip so atom keys become strings, as a verifier will see them
      CanonicalJSON.decode(json)
    else
      :error -> {:error, {:missing, :payload}}
      _ -> {:error, {:invalid, :payload}}
    end
  end

  defp fetch_issued_at(attrs) do
    case Map.get(attrs, :issued_at) do
      nil -> {:ok, DateTime.utc_now() |> DateTime.truncate(:second)}
      %DateTime{} = dt -> {:ok, to_utc_seconds(dt)}
      _ -> {:error, {:invalid, :issued_at}}
    end
  end

  defp fetch_expires_at(attrs, issued_at) do
    expires_at =
      case attrs do
        %{expires_at: %DateTime{} = dt} -> {:ok, to_utc_seconds(dt)}
        %{expires_at: _} -> {:error, {:invalid, :expires_at}}
        %{ttl_seconds: s} when is_integer(s) and s > 0 -> {:ok, DateTime.add(issued_at, s)}
        %{ttl_seconds: _} -> {:error, {:invalid, :ttl_seconds}}
        _ -> {:error, {:missing, :expires_at}}
      end

    case expires_at do
      {:ok, dt} ->
        if DateTime.after?(dt, issued_at), do: {:ok, dt}, else: {:error, {:invalid, :expires_at}}

      error ->
        error
    end
  end

  defp fetch_nonce(attrs) do
    case Map.get(attrs, :nonce) do
      nil -> {:ok, :crypto.strong_rand_bytes(@nonce_bytes) |> b64()}
      nonce -> if valid_nonce?(nonce), do: {:ok, nonce}, else: {:error, {:invalid, :nonce}}
    end
  end

  defp to_utc_seconds(dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  defp to_envelope(%__MODULE__{} = c) do
    %{
      "type" => c.type,
      "site_id" => c.site_id,
      "policy_version" => c.policy_version,
      "issued_at" => DateTime.to_iso8601(c.issued_at),
      "expires_at" => DateTime.to_iso8601(c.expires_at),
      "nonce" => c.nonce,
      "payload" => c.payload,
      "key_id" => c.key_id
    }
  end

  # parsing untrusted input: string keys only, never create atoms

  defp parse(%{"envelope" => envelope, "signature" => signature} = wire)
       when map_size(wire) == 2 and is_map(envelope) and is_binary(signature) do
    with true <- map_size(envelope) == length(@envelope_keys),
         true <- Enum.all?(@envelope_keys, &Map.has_key?(envelope, &1)),
         %{
           "type" => type,
           "site_id" => site_id,
           "policy_version" => version,
           "issued_at" => issued_at,
           "expires_at" => expires_at,
           "nonce" => nonce,
           "payload" => payload,
           "key_id" => key_id
         } = envelope,
         true <- non_empty_string?(type),
         true <- non_empty_string?(site_id),
         true <- non_empty_string?(key_id),
         true <- is_integer(version) and version >= 0,
         true <- is_map(payload),
         {:ok, issued_at} <- parse_datetime(issued_at),
         {:ok, expires_at} <- parse_datetime(expires_at),
         true <- DateTime.after?(expires_at, issued_at),
         true <- valid_nonce?(nonce),
         {:ok, sig} <- decode_b64(signature),
         true <- byte_size(sig) == @signature_bytes,
         # rejects floats or anything else a canonical encoding cannot represent
         {:ok, _} <- CanonicalJSON.encode(envelope) do
      command = %__MODULE__{
        type: type,
        site_id: site_id,
        policy_version: version,
        issued_at: issued_at,
        expires_at: expires_at,
        nonce: nonce,
        payload: payload,
        key_id: key_id
      }

      {:ok, command, envelope, sig}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parse(_wire), do: {:error, :malformed}

  defp non_empty_string?(s), do: is_binary(s) and s != "" and String.valid?(s)

  # only the exact form we emit: utc, seconds precision, trailing z
  defp parse_datetime(s) when is_binary(s) do
    with {:ok, dt, 0} <- DateTime.from_iso8601(s),
         dt = DateTime.truncate(dt, :second),
         true <- DateTime.to_iso8601(dt) == s do
      {:ok, dt}
    else
      _ -> :error
    end
  end

  defp parse_datetime(_), do: :error

  defp valid_nonce?(nonce) when is_binary(nonce) do
    match?({:ok, <<_::binary-size(@nonce_bytes)>>}, decode_b64(nonce))
  end

  defp valid_nonce?(_), do: false

  # base64url without padding, and only the canonical encoding of the decoded bytes,
  # so a value has exactly one accepted spelling
  defp decode_b64(s) do
    with {:ok, bytes} <- Base.url_decode64(s, padding: false),
         true <- b64(bytes) == s do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  # checks

  defp lookup_key(%Verifier{public_keys: keys}, key_id) do
    case Map.fetch(keys, key_id) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :unknown_key}
    end
  end

  defp check_signature(envelope, signature, public_key) do
    message = CanonicalJSON.encode!(envelope)

    if :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]),
      do: :ok,
      else: {:error, :bad_signature}
  end

  defp check_site(%{site_id: site_id}, %Verifier{site_id: site_id}), do: :ok
  defp check_site(_command, _verifier), do: {:error, :wrong_site}

  defp check_not_yet_valid(command, verifier, now) do
    latest = DateTime.add(now, verifier.max_skew_seconds)
    if DateTime.after?(command.issued_at, latest), do: {:error, :not_yet_valid}, else: :ok
  end

  defp check_expired(command, now) do
    if DateTime.before?(now, command.expires_at), do: :ok, else: {:error, :expired}
  end

  defp check_ttl(command, verifier) do
    ttl = DateTime.diff(command.expires_at, command.issued_at)
    if ttl > verifier.max_ttl_seconds, do: {:error, :ttl_too_long}, else: :ok
  end

  defp check_version(command, verifier) do
    if command.policy_version > verifier.last_version, do: :ok, else: {:error, :stale_version}
  end

  defp check_nonce(command, verifier) do
    if Map.has_key?(verifier.seen_nonces, command.nonce),
      do: {:error, :replayed_nonce},
      else: :ok
  end
end
