defmodule Gateway.Store do
  @moduledoc """
  The gateway's state on disk, under the `:data_dir` option.

    * `command.json` - the last accepted signed command, byte for byte as received.
      The Enforcer re-authenticates it at boot, so a file edited on disk is ignored.
    * `verifier.json` - `last_version` and `seen_nonces` of the command verifier.
      The site id and public keys always come from config, never from disk, so this
      file cannot widen trust.
    * `audit.jsonl` - the local audit chain: one `Breakline.AuditLog` record per
      line, appended and fsynced one at a time.

  `command.json` and `verifier.json` are replaced atomically: written to a temporary
  file in the same directory, fsynced, then renamed over the old file.

  At start the store reads `audit.jsonl` and verifies the chain. If a line does not
  decode or the chain is broken (including a line torn by a crash mid-append), the
  file is moved aside to `audit.jsonl.broken-<unix seconds>` and a new chain starts
  whose first entry, `audit_chain_reset`, records why and where the old file went. A
  broken chain is never continued silently.

  The chain id (`audit_chain_id/1`) is the hash of a chain's record 0, so a reset
  chain has a new one. The uplink sends it with the records (`audit_records/3`), so
  the cloud never mixes records of two chains.

  Options: `:data_dir` (required), `:clock` (a `Gateway.Clock`, for timestamps on the
  entries the store writes itself) and `:name` (defaults to this module).
  """

  use GenServer

  require Logger

  alias Breakline.AuditLog
  alias Breakline.CanonicalJSON

  @command "command.json"
  @verifier "verifier.json"
  @audit "audit.jsonl"

  @typedoc "Persisted verifier state."
  @type verifier_state :: %{
          last_version: non_neg_integer(),
          seen_nonces: %{optional(String.t()) => DateTime.t()}
        }

  @doc "Returns a child spec. See the moduledoc for options."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the store. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the raw bytes of `command.json`, or `:none` when there is none."
  @spec load_command(GenServer.server()) :: {:ok, binary()} | :none
  def load_command(server \\ __MODULE__), do: GenServer.call(server, :load_command)

  @doc "Atomically replaces `command.json` with `bytes`."
  @spec save_command(binary(), GenServer.server()) :: :ok | {:error, term()}
  def save_command(bytes, server \\ __MODULE__) when is_binary(bytes) do
    GenServer.call(server, {:save_command, bytes})
  end

  @doc """
  Returns the persisted verifier state, `:none` when the file does not exist or
  `{:error, reason}` when it exists but cannot be read or decoded.
  """
  @spec load_verifier_state(GenServer.server()) ::
          {:ok, verifier_state()} | :none | {:error, term()}
  def load_verifier_state(server \\ __MODULE__), do: GenServer.call(server, :load_verifier)

  @doc "Atomically replaces `verifier.json` with the verifier's version and nonces."
  @spec save_verifier_state(Breakline.Command.Verifier.t() | verifier_state(), GenServer.server()) ::
          :ok | {:error, term()}
  def save_verifier_state(verifier, server \\ __MODULE__) do
    GenServer.call(server, {:save_verifier, Map.take(verifier, [:last_version, :seen_nonces])})
  end

  @doc """
  Appends an entry (a json-compatible map) to the audit chain and fsyncs it.
  Returns the written record.
  """
  @spec audit(map(), GenServer.server()) :: {:ok, AuditLog.record()} | {:error, term()}
  def audit(entry, server \\ __MODULE__) when is_map(entry) do
    GenServer.call(server, {:audit, entry})
  end

  @doc "Returns the head `{seq, hash}` of the audit chain, or nil when it is empty."
  @spec audit_head(GenServer.server()) :: AuditLog.head()
  def audit_head(server \\ __MODULE__), do: GenServer.call(server, :audit_head)

  @doc """
  Returns the chain id of the audit chain: the hash of its record 0, or nil while the
  chain is empty. A chain reset starts a new chain, so it gets a new id.
  """
  @spec audit_chain_id(GenServer.server()) :: String.t() | nil
  def audit_chain_id(server \\ __MODULE__), do: GenServer.call(server, :audit_chain_id)

  @doc """
  Returns up to `limit` audit records starting at seq `from_seq`, oldest first, or
  `[]` when `from_seq` is past the head.
  """
  @spec audit_records(non_neg_integer(), pos_integer(), GenServer.server()) ::
          [AuditLog.record()]
  def audit_records(from_seq, limit, server \\ __MODULE__)
      when is_integer(from_seq) and from_seq >= 0 and is_integer(limit) and limit > 0 do
    GenServer.call(server, {:audit_records, from_seq, limit})
  end

  @doc "Returns the data directory."
  @spec data_dir(GenServer.server()) :: Path.t()
  def data_dir(server \\ __MODULE__), do: GenServer.call(server, :data_dir)

  @doc """
  Reads and verifies an `audit.jsonl` file without a running store. Returns the
  records, or `{:error, reason}` with `{:undecodable_line, index}` or the
  `Breakline.AuditLog.verify_chain/2` error.
  """
  @spec read_audit(Path.t(), keyword()) :: {:ok, [AuditLog.record()]} | {:error, term()}
  def read_audit(path, opts \\ []) do
    with {:ok, records} <- read_records(path),
         :ok <- AuditLog.verify_chain(records, opts) do
      {:ok, records}
    end
  end

  # server

  @impl true
  def init(opts) do
    dir = opts |> Keyword.fetch!(:data_dir) |> Path.expand()
    clock = Keyword.get(opts, :clock, Gateway.Clock.System)
    File.mkdir_p!(dir)

    audit_path = Path.join(dir, @audit)
    {head, chain_id, reset} = open_chain(audit_path, clock)
    {:ok, fd} = :file.open(audit_path, [:append, :binary, :raw])

    state = %{
      dir: dir,
      clock: clock,
      audit_path: audit_path,
      audit_fd: fd,
      head: head,
      chain_id: chain_id
    }

    state =
      case reset do
        nil ->
          state

        entry ->
          {:ok, _record, state} = append(entry, state)
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:load_command, _from, s) do
    reply =
      case File.read(Path.join(s.dir, @command)) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, _} -> :none
      end

    {:reply, reply, s}
  end

  def handle_call({:save_command, bytes}, _from, s) do
    {:reply, atomic_write(Path.join(s.dir, @command), bytes), s}
  end

  def handle_call(:load_verifier, _from, s) do
    {:reply, read_verifier(Path.join(s.dir, @verifier)), s}
  end

  def handle_call({:save_verifier, state}, _from, s) do
    json =
      CanonicalJSON.encode!(%{
        "last_version" => state.last_version,
        "seen_nonces" =>
          Map.new(state.seen_nonces, fn {nonce, exp} -> {nonce, DateTime.to_iso8601(exp)} end)
      })

    {:reply, atomic_write(Path.join(s.dir, @verifier), json), s}
  end

  def handle_call({:audit, entry}, _from, s) do
    case append(entry, s) do
      {:ok, record, s} -> {:reply, {:ok, record}, s}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call(:audit_head, _from, s), do: {:reply, s.head, s}
  def handle_call(:audit_chain_id, _from, s), do: {:reply, s.chain_id, s}

  def handle_call({:audit_records, from_seq, limit}, _from, s) do
    {:reply, records_from(s, from_seq, limit), s}
  end

  def handle_call(:data_dir, _from, s), do: {:reply, s.dir, s}

  @impl true
  def terminate(_reason, s), do: :file.close(s.audit_fd)

  # audit chain

  defp open_chain(path, clock) do
    case read_audit(path) do
      {:ok, []} ->
        {nil, nil, nil}

      {:ok, [first | _] = records} ->
        last = List.last(records)
        {{last["seq"], last["hash"]}, first["hash"], nil}

      {:error, :enoent} ->
        {nil, nil, nil}

      {:error, reason} ->
        now = clock.now()
        moved = "#{@audit}.broken-#{DateTime.to_unix(now)}"
        moved = unique_path(Path.join(Path.dirname(path), moved))
        File.rename!(path, moved)
        Logger.error("audit chain broken (#{inspect(reason)}), moved to #{moved}")

        entry = %{
          "type" => "audit_chain_reset",
          "at" => DateTime.to_iso8601(now),
          "reason" => inspect(reason),
          "moved_to" => Path.basename(moved)
        }

        {nil, nil, entry}
    end
  end

  defp unique_path(path) do
    if File.exists?(path), do: unique_path(path <> "-1"), else: path
  end

  defp append(entry, s) do
    record = AuditLog.append_record(s.head, entry)
    line = CanonicalJSON.encode!(record) <> "\n"

    with :ok <- :file.write(s.audit_fd, line),
         :ok <- :file.sync(s.audit_fd) do
      chain_id = s.chain_id || record["hash"]
      {:ok, record, %{s | head: {record["seq"], record["hash"]}, chain_id: chain_id}}
    else
      {:error, reason} ->
        Logger.error("audit append failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # line n of audit.jsonl is the record with seq n, and every line up to the head was
  # written and fsynced by this process, so reading lines is enough here
  defp records_from(%{head: nil}, _from_seq, _limit), do: []
  defp records_from(%{head: {head_seq, _}}, from_seq, _limit) when from_seq > head_seq, do: []

  defp records_from(s, from_seq, limit) do
    s.audit_path
    |> File.stream!(:line)
    |> Stream.drop(from_seq)
    |> Stream.take(limit)
    |> Enum.flat_map(fn line ->
      case CanonicalJSON.decode(String.trim_trailing(line, "\n")) do
        {:ok, record} when is_map(record) -> [record]
        _ -> []
      end
    end)
  end

  defp read_records(path) do
    case File.read(path) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n")
        |> drop_final_empty()
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
          case CanonicalJSON.decode(line) do
            {:ok, record} when is_map(record) -> {:cont, {:ok, [record | acc]}}
            _ -> {:halt, {:error, {:undecodable_line, index}}}
          end
        end)
        |> case do
          {:ok, rev} -> {:ok, Enum.reverse(rev)}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # a well formed file ends with a newline, so the last split piece is empty; a
  # torn final line has no newline and stays in the list, where it fails to decode
  defp drop_final_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  # files

  defp read_verifier(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"last_version" => v, "seen_nonces" => nonces} = map}
         when map_size(map) == 2 and is_integer(v) and v >= 0 and is_map(nonces) <-
           CanonicalJSON.decode(bytes),
         {:ok, nonces} <- decode_nonces(nonces) do
      {:ok, %{last_version: v, seen_nonces: nonces}}
    else
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  defp decode_nonces(nonces) do
    Enum.reduce_while(nonces, {:ok, %{}}, fn
      {nonce, exp}, {:ok, acc} when is_binary(exp) ->
        case DateTime.from_iso8601(exp) do
          {:ok, dt, 0} -> {:cont, {:ok, Map.put(acc, nonce, dt)}}
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  @doc false
  @spec atomic_write(Path.t(), iodata()) :: :ok | {:error, term()}
  def atomic_write(path, data) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    result =
      with {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw]),
           :ok <- write_sync_close(fd, data) do
        :file.rename(tmp, path)
      end

    if result != :ok, do: File.rm(tmp)
    result
  end

  defp write_sync_close(fd, data) do
    with :ok <- :file.write(fd, data),
         :ok <- :file.sync(fd) do
      :file.close(fd)
    else
      error ->
        :file.close(fd)
        error
    end
  end
end
