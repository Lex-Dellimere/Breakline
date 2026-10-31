defmodule Cloud.AuditExport do
  @moduledoc """
  A tenant's audit export: the records of its cloud audit chain (`Cloud.Audit`,
  D29) and of each site gateway's anchored audit chain
  (`Cloud.Gateways.AuditRecord`, D26) in a period, with the result of
  verifying every chain.

  `build/2` returns a plain, json-compatible map (string keys) in the format
  `"breakline-audit-export/1"`. `encode/1` turns it into the downloadable
  json, `to_render_model/1` into the rows and sentences a page or a PDF
  renders, and `export/2` builds it and records the export in the tenant's
  cloud audit chain (`"audit.exported"`).

  ## Verification

  Verification always runs over each whole chain, however short the period:

    * the cloud chain with `Cloud.Audit.verify/1`, against its stored head;
    * each site's current gateway chain (the chain id anchored on the site)
      with `Breakline.AuditLog.verify_chain/2`, from seq 0 against the
      anchored head. Chain resets (`"audit_chain_reset"` gateway events) are
      counted, since a reset starts a new chain and the old one is no longer
      verified.

  ## Records and offline verification

  For each chain the export holds the records whose `"at"` falls in the
  period, as one contiguous run of seqs (from the first record at or after
  `from` to the last one before `to`), plus the chain's head, the record just
  before the run (`"previous_record"`, null when the run starts at seq 0) and
  whether the run starts at genesis (`"from_genesis"`) and reaches the head
  (`"to_head"`). `Breakline.AuditExport` (and `mix breakline.audit.verify`)
  re-verifies each run offline from the previous record, and checks it
  against the head when it reaches it. An export whose period covers a
  whole chain is verified from genesis to head.

  ## Who may export

  Admins and approvers of the tenant. Every tenant-scoped read runs as the
  exporting user with the tenant. Three reads are trusted
  (`authorize?: false`), as their resources have no actor policies: the
  chain verification and head of `Cloud.Audit`, and the email addresses of
  the users named as actors in the exported entries.
  """

  alias Breakline.AuditLog
  alias Cloud.{Accounts, Audit, Gateways, Sites}
  alias Cloud.Accounts.User

  @format "breakline-audit-export/1"
  @default_days 30
  @roles [:admin, :approver]

  @coverage "Verification ran over each whole chain, not only the period. The records are " <>
              "those of the period, each chain's head when the export was made, and the record " <>
              "just before the period, so every period can be re-verified offline with " <>
              "mix breakline.audit.verify."

  @type export :: %{required(String.t()) => term()}

  @doc "The format string of the exports this module builds."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The roles allowed to export a tenant's audit."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc """
  Builds the export of `tenant_id`'s audit. Options:

    * `:actor` (required): the exporting `Cloud.Accounts.User`, an admin or
      approver of the tenant
    * `:from`, `:to`: the period as UTC datetimes, `[from, to)` (default:
      the last #{@default_days} days up to now)
    * `:site_ids`: the sites whose gateway chains to include (default all;
      ids of other tenants' sites are ignored)
    * `:now`: the generation time (default now)

  Returns `{:ok, export}`, `{:error, :forbidden}` for anyone else, or
  `{:error, :invalid_period}` when `to` is not after `from`.
  """
  @spec build(String.t(), keyword()) :: {:ok, export()} | {:error, atom()}
  def build(tenant_id, opts) when is_binary(tenant_id) do
    actor = Keyword.fetch!(opts, :actor)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    to = opts[:to] || now
    from = opts[:from] || DateTime.add(to, -@default_days * 86_400, :second)

    with {:ok, role} <- role(actor, tenant_id),
         :ok <- check_period(from, to),
         {:ok, tenant} <- tenant(actor, tenant_id) do
      sites = sites(actor, tenant_id, opts[:site_ids])
      cloud = cloud_chain(actor, tenant_id, from, to)
      gateways = Enum.map(sites, &gateway_chain(actor, &1, from, to))

      {:ok,
       %{
         "format" => @format,
         "generated_at" => iso(now),
         "tenant" => %{"id" => tenant.id, "name" => tenant.name, "slug" => tenant.slug},
         "period" => %{"from" => iso(from), "to" => iso(to)},
         "exported_by" => %{
           "id" => actor.id,
           "email" => to_string(actor.email),
           "role" => Atom.to_string(role)
         },
         "sites" =>
           Enum.map(sites, &%{"id" => &1.id, "name" => &1.name, "time_zone" => &1.time_zone}),
         "coverage" => @coverage,
         "verification" => %{
           "scope" => "whole_chain",
           "cloud" => cloud.verification,
           "gateways" => Enum.map(gateways, & &1.verification)
         },
         "cloud_audit" => cloud.segment,
         "gateway_audit" => Enum.map(gateways, & &1.segment)
       }}
    end
  end

  @doc """
  Builds the export (see `build/2`) and records it in the tenant's cloud
  audit chain as `"audit.exported"` with the period, the site ids and the
  actor, never the data. Use this for every export that leaves the cloud.
  """
  @spec export(String.t(), keyword()) :: {:ok, export()} | {:error, term()}
  def export(tenant_id, opts) do
    with {:ok, export} <- build(tenant_id, opts),
         {:ok, _entry} <-
           Audit.record(
             tenant_id,
             "audit.exported",
             %{
               from: export["period"]["from"],
               to: export["period"]["to"],
               site_ids: Enum.map(export["sites"], & &1["id"]),
               format: @format
             },
             actor: Keyword.fetch!(opts, :actor)
           ) do
      {:ok, export}
    end
  end

  @doc "The export as pretty-printed json, `\"format\"` first."
  @spec encode(export()) :: iodata()
  def encode(export) do
    keys =
      ~w(format generated_at tenant period exported_by sites coverage verification cloud_audit gateway_audit)

    rest = export |> Map.drop(keys) |> Enum.sort()

    (Enum.map(keys, &{&1, Map.get(export, &1)}) ++ rest)
    |> Jason.OrderedObject.new()
    |> Jason.encode_to_iodata!(pretty: true)
  end

  @doc """
  The download filename:
  `breakline-audit-<tenant-slug>-<from>-<to>.json`, with the UTC dates of the
  period's first and last day.
  """
  @spec filename(export(), String.t()) :: String.t()
  def filename(export, extension \\ "json") do
    slug = export["tenant"]["slug"]
    from = date(export["period"]["from"], 0)
    # the period ends just before `to`, so a period up to midnight is named by its last day
    to = date(export["period"]["to"], -1)
    "breakline-audit-#{slug}-#{from}-#{to}.#{extension}"
  end

  @doc """
  What a page or a printed report shows of an export, without any markup:

    * `:title`, `:tenant`, `:period`, `:generated_at`, `:exported_by` and
      `:coverage`: strings
    * `:verification`: one `%{chain, ok?, summary}` per chain, the cloud chain
      first, `summary` a sentence such as `"Cloud audit chain: intact, 123
      entries, head seq 122"`
    * `:sections`: `%{title, columns, rows}` tables of the records, the
      cloud entries first, then one per gateway chain; every cell a string

  The PDF renderer (pending a library decision) renders exactly this model,
  so a printed report and the json download always come from the same data.
  """
  @spec to_render_model(export()) :: map()
  def to_render_model(export) do
    %{
      title: "Breakline audit export",
      tenant: export["tenant"]["name"],
      period:
        "#{display_time(export["period"]["from"])} to #{display_time(export["period"]["to"])}",
      generated_at: display_time(export["generated_at"]),
      exported_by: export["exported_by"]["email"],
      coverage: export["coverage"],
      verification:
        [cloud_summary(export["verification"]["cloud"])] ++
          Enum.map(export["verification"]["gateways"], &gateway_summary/1),
      sections:
        [cloud_section(export["cloud_audit"])] ++
          Enum.map(export["gateway_audit"], &gateway_section/1)
    }
  end

  # access

  defp role(%User{id: user_id}, tenant_id) do
    case Accounts.membership_for(user_id, tenant_id, authorize?: false) do
      {:ok, %{role: role}} when role in @roles -> {:ok, role}
      _ -> {:error, :forbidden}
    end
  end

  defp role(_actor, _tenant_id), do: {:error, :forbidden}

  defp tenant(actor, tenant_id) do
    case Accounts.get_tenant(tenant_id, actor: actor, not_found_error?: false) do
      {:ok, %{} = tenant} -> {:ok, tenant}
      _ -> {:error, :forbidden}
    end
  end

  defp check_period(%DateTime{} = from, %DateTime{} = to) do
    if DateTime.compare(from, to) == :lt, do: :ok, else: {:error, :invalid_period}
  end

  defp check_period(_from, _to), do: {:error, :invalid_period}

  defp sites(actor, tenant_id, site_ids) do
    sites =
      Sites.list_sites!(actor: actor, tenant: tenant_id)
      |> Enum.sort_by(&{String.downcase(&1.name), &1.id})

    case site_ids do
      nil -> sites
      ids -> Enum.filter(sites, &(&1.id in ids))
    end
  end

  # the cloud chain

  defp cloud_chain(actor, tenant_id, from, to) do
    # the head is read first: entries appended after it are left out, so the
    # records, the head and the counts all describe the same chain
    head =
      case Audit.get_head(tenant_id, authorize?: false, not_found_error?: false) do
        {:ok, %{seq: seq, hash: hash}} when is_integer(seq) -> %{"seq" => seq, "hash" => hash}
        _ -> nil
      end

    entries =
      Audit.audit_chain!(actor: actor, tenant: tenant_id)
      |> Enum.filter(&(head && &1.seq <= head["seq"]))

    emails = Accounts.emails_by_id(Enum.map(entries, & &1.actor_id))

    items =
      Enum.map(entries, fn entry ->
        {entry_at(entry.entry["at"], entry.inserted_at), cloud_item(entry, emails)}
      end)

    verification =
      case Audit.verify(tenant_id) do
        :ok -> %{"status" => "intact", "break" => nil}
        {:error, {:broken_at, seq, reason}} -> broken(seq, reason)
      end

    %{
      verification: Map.merge(verification, %{"entries" => length(entries), "head" => head}),
      segment: segment(items, head, from, to)
    }
  end

  defp cloud_item(entry, emails) do
    %{
      "seq" => entry.seq,
      "at" => entry.entry["at"],
      "actor_id" => entry.actor_id,
      "actor_email" => entry.actor_id && Map.get(emails, entry.actor_id),
      "action" => entry.entry["action"],
      "entry" => entry.entry,
      "prev_hash" => entry.prev_hash,
      "hash" => entry.hash
    }
  end

  # one gateway chain

  defp gateway_chain(actor, site, from, to) do
    chain_id = site.gateway_audit_chain_id
    head = head_map(site.gateway_audit_head)

    records =
      case chain_id do
        nil ->
          []

        chain_id ->
          Gateways.list_audit_records!(
            actor: actor,
            tenant: site.tenant_id,
            query: [filter: [site_id: site.id, chain_id: chain_id], sort: [seq: :asc]]
          )
          # records stored after the site was read are not covered by its head
          |> Enum.filter(&(head && &1.seq <= head["seq"]))
      end

    resets =
      Gateways.list_events!(
        actor: actor,
        tenant: site.tenant_id,
        query: [filter: [site_id: site.id, type: "audit_chain_reset"], select: [:id]]
      )
      |> length()

    status = verify_gateway(chain_id, records, head)

    items =
      Enum.map(records, fn row ->
        {entry_at(get_in(row.record, ["entry", "at"]), row.inserted_at), gateway_item(row)}
      end)

    %{
      verification:
        Map.merge(status, %{
          "site_id" => site.id,
          "site_name" => site.name,
          "chain_id" => chain_id,
          "anchored_head" => head,
          "records" => length(records),
          "chain_resets" => resets
        }),
      segment:
        Map.merge(segment(items, head, from, to), %{
          "site_id" => site.id,
          "site_name" => site.name,
          "time_zone" => site.time_zone,
          "chain_id" => chain_id
        })
    }
  end

  defp verify_gateway(nil, _records, _head), do: %{"status" => "no_chain", "break" => nil}

  defp verify_gateway(_chain_id, records, head) do
    records
    |> Enum.map(& &1.record)
    |> AuditLog.verify_chain(expected_head: head && {head["seq"], head["hash"]})
    |> case do
      :ok -> %{"status" => "intact", "break" => nil}
      {:error, {:broken_at, seq, reason}} -> broken(seq, reason)
    end
  end

  defp gateway_item(row) do
    %{
      "seq" => row.seq,
      "prev_hash" => row.record["prev_hash"],
      "hash" => row.hash,
      "record" => row.record
    }
  end

  # the period's records of one chain, as one contiguous run of seqs

  defp segment(items, head, from, to) do
    total = length(items)
    start = Enum.find_index(items, fn {at, _} -> DateTime.compare(at, from) != :lt end) || total

    run =
      items
      |> Enum.drop(start)
      |> Enum.take_while(fn {at, _} -> DateTime.compare(at, to) == :lt end)
      |> Enum.map(&elem(&1, 1))

    previous = if start > 0, do: items |> Enum.at(start - 1) |> elem(1)

    %{
      "head" => head,
      "previous_record" => previous,
      "records" => run,
      "from_genesis" => start == 0,
      "to_head" => start + length(run) == total
    }
  end

  defp entry_at(iso, fallback) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> at
      _ -> fallback
    end
  end

  defp entry_at(_iso, fallback), do: fallback

  defp broken(seq, reason),
    do: %{"status" => "broken", "break" => %{"seq" => seq, "reason" => Atom.to_string(reason)}}

  defp head_map(%{"seq" => seq, "hash" => hash}) when is_integer(seq) and is_binary(hash),
    do: %{"seq" => seq, "hash" => hash}

  defp head_map(_head), do: nil

  # the render model

  @reasons %{
    "malformed" => "a record is malformed",
    "seq_gap" => "a record is missing or out of order",
    "prev_mismatch" => "a record does not link to the one before it",
    "hash_mismatch" => "a record does not match its hash",
    "truncated" => "records are missing at the end of the chain",
    "head_mismatch" => "the chain does not end at its anchored head"
  }

  @doc "A short explanation of a chain break reason, such as `\"hash_mismatch\"`."
  @spec explain_reason(String.t()) :: String.t()
  def explain_reason(reason), do: Map.get(@reasons, reason, reason)

  defp cloud_summary(%{"status" => "intact", "entries" => 0}),
    do: %{
      chain: "Cloud audit chain",
      ok?: true,
      summary: "Cloud audit chain: intact, no entries yet"
    }

  defp cloud_summary(%{"status" => "intact", "entries" => n, "head" => head}),
    do: %{
      chain: "Cloud audit chain",
      ok?: true,
      summary:
        "Cloud audit chain: intact, #{n} #{plural(n, "entry", "entries")}, head seq #{head["seq"]}"
    }

  defp cloud_summary(%{"break" => %{"seq" => seq, "reason" => reason}}),
    do: %{
      chain: "Cloud audit chain",
      ok?: false,
      summary: "Cloud audit chain: broken at seq #{seq}: #{explain_reason(reason)} (#{reason})"
    }

  defp gateway_summary(%{"status" => "no_chain", "site_name" => name}),
    do: %{
      chain: "Gateway chain of #{name}",
      ok?: true,
      summary: "Gateway chain of #{name}: no audit chain anchored yet"
    }

  defp gateway_summary(%{"status" => "intact", "site_name" => name} = v) do
    head = if v["anchored_head"], do: ", head seq #{v["anchored_head"]["seq"]}", else: ""

    %{
      chain: "Gateway chain of #{name}",
      ok?: true,
      summary:
        "Gateway chain of #{name}: intact, #{v["records"]} #{plural(v["records"], "record", "records")}" <>
          head <> resets(v["chain_resets"])
    }
  end

  defp gateway_summary(
         %{"break" => %{"seq" => seq, "reason" => reason}, "site_name" => name} = v
       ),
       do: %{
         chain: "Gateway chain of #{name}",
         ok?: false,
         summary:
           "Gateway chain of #{name}: broken at seq #{seq}: #{explain_reason(reason)} (#{reason})" <>
             resets(v["chain_resets"])
       }

  defp resets(0), do: ""
  defp resets(n), do: ", #{n} chain #{plural(n, "reset", "resets")} recorded"

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  defp cloud_section(segment) do
    %{
      title: "Cloud audit entries",
      columns: ["Seq", "Time (UTC)", "Actor", "Action", "Hash"],
      rows:
        Enum.map(segment["records"], fn r ->
          [
            Integer.to_string(r["seq"]),
            display_time(r["at"]),
            r["actor_email"] || if(r["actor_id"], do: r["actor_id"], else: "system"),
            to_string(r["action"]),
            short_hash(r["hash"])
          ]
        end)
    }
  end

  defp gateway_section(segment) do
    %{
      title: "Gateway audit: #{segment["site_name"]}",
      columns: ["Seq", "Time (UTC)", "Type", "Hash"],
      rows:
        Enum.map(segment["records"], fn r ->
          entry = r["record"]["entry"] || %{}

          [
            Integer.to_string(r["seq"]),
            display_time(entry["at"]),
            to_string(entry["type"] || ""),
            short_hash(r["hash"])
          ]
        end)
    }
  end

  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)
  defp short_hash(_hash), do: ""

  defp display_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
      _ -> iso
    end
  end

  defp display_time(_iso), do: ""

  defp date(iso, shift_us) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} ->
        at |> DateTime.add(shift_us, :microsecond) |> DateTime.to_date() |> Date.to_iso8601()

      _ ->
        "unknown"
    end
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
end
