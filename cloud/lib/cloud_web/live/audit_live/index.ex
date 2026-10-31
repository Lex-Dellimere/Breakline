defmodule CloudWeb.AuditLive.Index do
  @moduledoc """
  The audit page: pick a tenant, a period (the last 7 or 30 days, or custom
  dates) and sites, see whether each hash chain verifies, preview the most
  recent entries of the period, and download the export as json or as a PDF
  report (`CloudWeb.AuditExportController`).

  The preview is `Cloud.AuditExport.build/2` for the same period and sites
  as the download link, read as the user, and is not recorded; only a
  download is. The verification sentences come from
  `Cloud.AuditExport.to_render_model/1`, the same model the PDF report is
  rendered from. A period with more records than one PDF holds
  (`Cloud.AuditExport.PDF.max_records/0`) shows the PDF button disabled with
  a note to pick a shorter period.

  The choices live in the url (`?tenant=&preset=&from=&to=&site_ids=`), so a
  view can be shared and reloaded. Admins and approvers of a tenant may use
  it (every membership is one of the two).
  """

  use CloudWeb, :live_view

  alias Cloud.AuditExport
  alias Cloud.AuditExport.PDF
  alias CloudWeb.AuditParams
  alias CloudWeb.SitesLive.Data

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @presets [
    {"7d", "Last 7 days", 7},
    {"30d", "Last 30 days", 30},
    {"custom", "Custom dates", nil}
  ]
  @preview 10

  @impl true
  def mount(_params, _session, socket) do
    case Data.tenants(socket.assigns.current_user) do
      [] ->
        {:ok,
         socket
         |> put_flash(:error, "Only a tenant's admins and approvers can export its audit")
         |> push_navigate(to: ~p"/dashboard")}

      tenants ->
        {:ok,
         socket
         |> assign(:page_title, "Audit")
         |> assign(:tenants, tenants)
         |> assign(:presets, Enum.map(@presets, fn {id, label, _} -> {id, label} end))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tenants = socket.assigns.tenants
    tenant = Enum.find(tenants, hd(tenants), &(&1.id == params["tenant"]))
    sites = Data.tenant_sites(socket.assigns.current_user, tenant.id)

    preset =
      if params["preset"] in Enum.map(@presets, &elem(&1, 0)), do: params["preset"], else: "7d"

    site_ids = selected_site_ids(params, sites)

    socket =
      socket
      |> assign(:tenant, tenant)
      |> assign(:sites, sites)
      |> assign(:preset, preset)
      |> assign(:site_ids, site_ids)

    case period(preset, params) do
      {:ok, from, to} ->
        {:noreply, socket |> assign(:period_error, nil) |> preview(from, to, params)}

      :error ->
        {:noreply,
         socket
         |> assign(:period_error, "Pick a start date before the end date")
         |> assign(:form, form(preset, params["from"], params["to"]))
         |> assign(:model, nil)
         |> assign(:download_url, nil)
         |> assign(:pdf_url, nil)}
    end
  end

  # only the tenant's own site ids count; all of them, or none, means every site
  defp selected_site_ids(params, sites) do
    ids = AuditParams.site_ids(params) || []
    own = sites |> Enum.map(& &1.id) |> Enum.filter(&(&1 in ids))
    if own == [] or length(own) == length(sites), do: nil, else: own
  end

  defp period(preset, params) do
    now = DateTime.utc_now()

    case List.keyfind(@presets, preset, 0) do
      {_, _, nil} -> AuditParams.period(params, now)
      {_, _, days} -> {:ok, DateTime.add(now, -days * 86_400, :second), now}
    end
  end

  defp preview(socket, from, to, params) do
    tenant = socket.assigns.tenant

    case AuditExport.build(tenant.id,
           actor: socket.assigns.current_user,
           from: from,
           to: to,
           site_ids: socket.assigns.site_ids
         ) do
      {:ok, export} ->
        model = AuditExport.to_render_model(export)

        socket
        |> assign(:model, model)
        |> assign(:recent, recent(export))
        |> assign(
          :gateway_counts,
          Enum.map(export["gateway_audit"], &{&1["site_name"], length(&1["records"])})
        )
        |> assign(:filename, AuditExport.filename(export))
        |> assign(:download_url, download_url(tenant.id, from, to, socket.assigns.site_ids))
        |> assign(:pdf_url, download_url(tenant.id, from, to, socket.assigns.site_ids, :pdf))
        |> assign(:pdf_records, PDF.record_count(model))
        |> assign(
          :form,
          form(socket.assigns.preset, params["from"] || date(from), params["to"] || date(to, -1))
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "You cannot export this tenant's audit")
        |> push_navigate(to: ~p"/dashboard")
    end
  end

  defp recent(export) do
    export["cloud_audit"]["records"]
    |> Enum.reverse()
    |> Enum.take(@preview)
  end

  defp download_url(tenant_id, from, to, site_ids, format \\ :json) do
    query =
      [tenant: tenant_id, from: DateTime.to_iso8601(from), to: DateTime.to_iso8601(to)] ++
        if(site_ids, do: [site_ids: Enum.join(site_ids, ",")], else: [])

    case format do
      :json -> ~p"/audit/export.json?#{query}"
      :pdf -> ~p"/audit/export.pdf?#{query}"
    end
  end

  defp form(preset, from, to),
    do: to_form(%{"preset" => preset, "from" => from, "to" => to}, as: :audit)

  defp date(at, shift_us \\ 0),
    do: at |> DateTime.add(shift_us, :microsecond) |> DateTime.to_date() |> Date.to_iso8601()

  @impl true
  def handle_event("change", %{"audit" => audit}, socket) do
    site_ids =
      case AuditParams.site_ids(audit) do
        nil -> []
        ids -> ids
      end

    query =
      [tenant: socket.assigns.tenant.id, preset: audit["preset"]] ++
        if(audit["preset"] == "custom", do: [from: audit["from"], to: audit["to"]], else: []) ++
        if(site_ids != [] and length(site_ids) < length(socket.assigns.sites),
          do: [site_ids: Enum.join(site_ids, ",")],
          else: []
        )

    {:noreply, push_patch(socket, to: ~p"/audit?#{query}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Audit</h1>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            {@tenant.name}'s cloud audit chain and each gateway's audit chain, verified end to end, with an export an auditor can re-check offline.
          </p>
        </div>
        <div :if={length(@tenants) > 1} id="tenant-picker" class="flex flex-wrap gap-2">
          <.button_link
            :for={tenant <- @tenants}
            id={"tenant-#{tenant.id}"}
            patch={~p"/audit?#{[tenant: tenant.id]}"}
            variant={if(tenant.id == @tenant.id, do: "default", else: "bordered")}
            color={if(tenant.id == @tenant.id, do: "primary", else: "natural")}
            size="small"
          >
            {tenant.name}
          </.button_link>
        </div>
      </div>

      <.card id="audit-options" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_content>
          <.form_wrapper for={@form} id="audit-form" phx-change="change" space="small">
            <div class="grid gap-3 sm:grid-cols-3">
              <.native_select field={@form[:preset]} label="Period" size="small">
                <:option
                  :for={{id, label} <- @presets}
                  value={id}
                  selected={@preset == id}
                >
                  {label}
                </:option>
              </.native_select>
              <.date_time_field
                :if={@preset == "custom"}
                field={@form[:from]}
                type="date"
                label="From"
                size="small"
              />
              <.date_time_field
                :if={@preset == "custom"}
                field={@form[:to]}
                type="date"
                label="To (inclusive)"
                size="small"
              />
            </div>
            <p :if={@period_error} id="period-error" class="text-sm text-rose-600">
              {@period_error}
            </p>
            <fieldset :if={@sites != []} id="audit-sites" class="space-y-2">
              <legend class="text-sm font-medium">Sites</legend>
              <div class="grid gap-1 sm:grid-cols-2">
                <.checkbox_field
                  :for={site <- @sites}
                  id={"audit-site-#{site.id}"}
                  name="audit[site_ids][]"
                  value={site.id}
                  checked={is_nil(@site_ids) or site.id in @site_ids}
                  label={site.name}
                  size="small"
                />
              </div>
              <p class="text-xs text-zinc-500">
                Leaving every site unticked exports them all.
              </p>
            </fieldset>
          </.form_wrapper>
        </.card_content>
      </.card>

      <%= if @model do %>
        <.card id="verification" variant="bordered" color="natural" rounded="large" padding="large">
          <.card_title title="Verification" size="small" font_weight="font-semibold" />
          <.card_content>
            <p class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
              Each chain is verified as a whole, from its first record to its anchored head, whatever the period.
            </p>
            <ul class="space-y-2">
              <li
                :for={{v, i} <- Enum.with_index(@model.verification)}
                id={"verification-#{i}"}
                class={[
                  "flex items-start gap-2 text-base font-medium",
                  v.ok? && "text-emerald-700 dark:text-emerald-400",
                  !v.ok? && "text-red-700 dark:text-red-400"
                ]}
              >
                <.icon
                  name={if(v.ok?, do: "hero-check-badge", else: "hero-exclamation-triangle")}
                  class="mt-0.5 size-5 shrink-0"
                />
                <span>{v.summary}</span>
              </li>
            </ul>
          </.card_content>
        </.card>

        <.card id="export" variant="bordered" color="natural" rounded="large" padding="large">
          <.card_title title="Export" size="small" font_weight="font-semibold" />
          <.card_content>
            <p class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
              {@model.period}. The download is recorded in the audit chain. Re-check a file offline with
              <code class="rounded bg-zinc-100 px-1 font-mono text-xs dark:bg-zinc-800">
                mix breakline.audit.verify {@filename}
              </code>
            </p>
            <div class="flex flex-wrap gap-2">
              <.button_link
                id="download-json"
                href={@download_url}
                variant="default"
                color="primary"
                size="small"
                icon="hero-arrow-down-tray"
              >
                Download JSON
              </.button_link>
              <.button_link
                :if={@pdf_records <= PDF.max_records()}
                id="download-pdf"
                href={@pdf_url}
                variant="bordered"
                color="natural"
                size="small"
                icon="hero-document"
              >
                Download PDF
              </.button_link>
              <.button
                :if={@pdf_records > PDF.max_records()}
                id="download-pdf"
                disabled
                variant="bordered"
                color="natural"
                size="small"
                icon="hero-document"
              >
                PDF
              </.button>
            </div>
            <p
              :if={@pdf_records > PDF.max_records()}
              id="pdf-too-large"
              class="mt-2 text-xs text-zinc-500"
            >
              This period has {@pdf_records} records, more than the {PDF.max_records()} one PDF can hold. Pick a shorter period for the PDF; the json export has them all.
            </p>
          </.card_content>
        </.card>

        <.card id="preview" variant="bordered" color="natural" rounded="large" padding="large">
          <.card_title title="Most recent cloud entries" size="small" font_weight="font-semibold" />
          <.card_content>
            <p :if={@recent == []} id="preview-empty" class="text-sm text-zinc-500">
              No cloud audit entries in this period.
            </p>
            <ul
              :if={@recent != []}
              id="preview-entries"
              class="divide-y divide-zinc-100 text-sm dark:divide-zinc-800"
            >
              <li
                :for={r <- @recent}
                id={"preview-entry-#{r["seq"]}"}
                class="flex flex-wrap items-baseline gap-x-3 py-2"
              >
                <span class="w-10 shrink-0 tabular-nums text-zinc-500">#{r["seq"]}</span>
                <span class="w-40 shrink-0 tabular-nums text-zinc-500">{display_time(r["at"])}</span>
                <span class="font-medium">{r["action"]}</span>
                <span class="text-xs text-zinc-500">{r["actor_email"] || "system"}</span>
              </li>
            </ul>
            <p :if={@gateway_counts != []} id="preview-gateways" class="mt-3 text-xs text-zinc-500">
              Gateway records in this period: {Enum.map_join(@gateway_counts, ", ", fn {name, n} ->
                "#{name} #{n}"
              end)}.
            </p>
          </.card_content>
        </.card>
      <% end %>
    </Layouts.app>
    """
  end

  defp display_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
      _ -> iso
    end
  end

  defp display_time(_iso), do: ""
end
