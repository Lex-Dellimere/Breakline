defmodule Gateway.DNS.Snapshot do
  @moduledoc """
  The decision state the resolver reads on every query, kept in
  `:persistent_term` so reads cost nothing and need no process.

  The enforcer owns it and calls `put/1` whenever the schedule state, mode or
  policy changes. Until something has been put, `get/0` returns the fail-closed
  default: locked, enforcing, every catalog tool, no site hostnames. A gateway
  that boots without a policy therefore blocks the RMM tools from the first
  query.

  Writes to `:persistent_term` trigger a global scan of all processes, so the
  enforcer should only put when something actually changed.
  """

  @key {__MODULE__, :current}

  @enforce_keys [:locked?, :mode, :tool_ids]
  defstruct locked?: true, mode: :enforce, tool_ids: [], site_hostnames: []

  @type t :: %__MODULE__{
          locked?: boolean(),
          mode: :enforce | :monitor,
          tool_ids: [String.t()],
          site_hostnames: [String.t()]
        }

  @doc """
  Stores a snapshot. Site hostnames are lowercased and lose one trailing dot so
  lookups can compare them directly with normalised query names.
  """
  @spec put(t()) :: :ok
  def put(%__MODULE__{locked?: locked?, mode: mode, tool_ids: ids, site_hostnames: hosts} = snap)
      when is_boolean(locked?) and mode in [:enforce, :monitor] and is_list(ids) and
             is_list(hosts) do
    snap = %{snap | site_hostnames: hosts |> Enum.map(&normalize/1) |> Enum.uniq()}
    :persistent_term.put(@key, snap)
  end

  @doc "Returns the current snapshot, or the fail-closed default if none was put."
  @spec get() :: t()
  def get do
    case :persistent_term.get(@key, nil) do
      nil -> default()
      snap -> snap
    end
  end

  @doc "Returns the fail-closed default snapshot."
  @spec default() :: t()
  def default do
    %__MODULE__{
      locked?: true,
      mode: :enforce,
      tool_ids: Breakline.Catalog.ids(),
      site_hostnames: []
    }
  end

  @doc "Removes the stored snapshot, so `get/0` falls back to the default. Used by tests."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Normalises a domain name the way the resolver compares names: ascii
  lowercase (dns case-insensitivity is ascii only, and names off the wire need
  not be valid utf-8), one trailing dot removed.

      iex> Gateway.DNS.Snapshot.normalize("Support.MSP.example.")
      "support.msp.example"
  """
  @spec normalize(binary()) :: binary()
  def normalize(name) when is_binary(name) do
    lower = for <<c <- name>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>
    String.replace_suffix(lower, ".", "")
  end
end
