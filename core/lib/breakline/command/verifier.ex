defmodule Breakline.Command.Verifier do
  @moduledoc """
  The gateway's trust state for verifying `Breakline.Command`s.

  Holds the site this gateway belongs to, the trusted Ed25519 public keys by `key_id`,
  the last accepted policy version and the nonces of accepted commands that have not
  expired yet. `Breakline.Command.verify/3` returns an updated verifier on success; the
  gateway persists it so versions keep increasing across restarts (threat model T4).

  `last_version` starts at 0, so the first acceptable command has version 1.
  """

  @enforce_keys [:site_id, :public_keys]
  defstruct site_id: nil,
            public_keys: %{},
            last_version: 0,
            seen_nonces: %{},
            max_skew_seconds: 300,
            max_ttl_seconds: 86_400

  @type t :: %__MODULE__{
          site_id: String.t(),
          public_keys: %{optional(String.t()) => Breakline.Command.public_key()},
          last_version: non_neg_integer(),
          seen_nonces: %{optional(String.t()) => DateTime.t()},
          max_skew_seconds: non_neg_integer(),
          max_ttl_seconds: pos_integer()
        }

  @doc """
  Builds a verifier. Requires `:site_id` and `:public_keys` (a map of key id to 32 byte
  public key); `:last_version`, `:seen_nonces`, `:max_skew_seconds` and
  `:max_ttl_seconds` are optional. Raises `ArgumentError` on invalid options.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts) do
    verifier = struct!(__MODULE__, Map.new(opts))

    valid? =
      is_binary(verifier.site_id) and verifier.site_id != "" and
        is_map(verifier.public_keys) and
        Enum.all?(verifier.public_keys, fn {id, key} ->
          is_binary(id) and id != "" and is_binary(key) and byte_size(key) == 32
        end) and
        is_integer(verifier.last_version) and verifier.last_version >= 0 and
        is_map(verifier.seen_nonces) and
        Enum.all?(verifier.seen_nonces, fn {n, exp} ->
          is_binary(n) and is_struct(exp, DateTime)
        end) and
        is_integer(verifier.max_skew_seconds) and verifier.max_skew_seconds >= 0 and
        is_integer(verifier.max_ttl_seconds) and verifier.max_ttl_seconds > 0

    if valid?, do: verifier, else: raise(ArgumentError, "invalid verifier options")
  end

  @doc """
  Drops recorded nonces whose `expires_at` is at or before `now`. Such commands are
  rejected as expired anyway, so their nonces no longer need remembering.
  """
  @spec prune(t(), DateTime.t()) :: t()
  def prune(%__MODULE__{} = verifier, %DateTime{} = now) do
    seen = Map.filter(verifier.seen_nonces, fn {_nonce, exp} -> DateTime.after?(exp, now) end)
    %{verifier | seen_nonces: seen}
  end
end
