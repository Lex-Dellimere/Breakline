defmodule Cloud.AuditExport.PDF do
  @moduledoc """
  Renders an audit export's render model (`Cloud.AuditExport.to_render_model/1`)
  as a PDF with the pinned Typst CLI (`Cloud.Typst`, D38).

  Each render gets a fresh private temporary directory holding `data.json`
  (the render model) and the template `priv/typst/audit.typ`, and runs

      timeout -k 5 <timeout> typst compile --ignore-system-fonts --root <dir> \\
        --package-path <dir>/packages --package-cache-path <dir>/packages \\
        audit.typ out.pdf

  in it, with `SOURCE_DATE_EPOCH` set to the export's generation time, so the
  same export always renders to the same bytes. The directory is removed
  afterwards, whether the render worked or not.

  The template reads the data with `json("data.json")` and shows every value
  as text: nothing from the export is written into Typst source or
  evaluated, so markup in an audit entry (which an attacker can influence)
  prints literally. The template imports no package, so Typst never touches
  the network, and the package paths point into the empty render directory.
  Only the fonts embedded in the binary are used.

  Limits: a render model with more than #{20_000} records is refused before
  Typst runs (ask for a shorter period), and Typst is killed after the
  timeout (default 60 seconds; `timeout` sends TERM, then KILL 5 seconds
  later).
  """

  @max_records 20_000
  @timeout_s 60

  @type error ::
          {:typst_missing, String.t()}
          | :timeout_missing
          | {:too_many_records, non_neg_integer(), pos_integer()}
          | :timeout
          | {:typst_failed, integer(), String.t()}
          | {:io, term()}

  @doc """
  The most records a single PDF may hold: `:cloud, :audit_pdf_max_records`,
  else #{20_000}.
  """
  @spec max_records() :: pos_integer()
  def max_records, do: Application.get_env(:cloud, :audit_pdf_max_records, @max_records)

  @doc "The number of record rows in a render model, across all its tables."
  @spec record_count(map()) :: non_neg_integer()
  def record_count(model), do: model.sections |> Enum.map(&length(&1.rows)) |> Enum.sum()

  @doc """
  Renders `model` to PDF bytes. Options (mostly for tests):

    * `:typst_path`: the binary (default `Cloud.Typst.path/0`)
    * `:timeout`: seconds before Typst is killed (default
      `:cloud, :typst_timeout`, else #{@timeout_s})
    * `:max_records`: the record limit (default `max_records/0`)
    * `:format`: `"pdf"` (default), or `"png"` / `"svg"` with `:pages` for
      previews; with several pages the result is the first page's bytes
    * `:pages`: Typst's page selection, such as `"1"`

  Returns `{:ok, binary}` or `{:error, reason}`; `message/1` explains a reason.
  """
  @spec render(map(), keyword()) :: {:ok, binary()} | {:error, error()}
  def render(model, opts \\ []) do
    typst = Keyword.get_lazy(opts, :typst_path, &Cloud.Typst.path/0)
    timeout = opts[:timeout] || Application.get_env(:cloud, :typst_timeout, @timeout_s)
    max = opts[:max_records] || max_records()
    count = record_count(model)

    cond do
      count > max -> {:error, {:too_many_records, count, max}}
      not executable?(typst) -> {:error, {:typst_missing, typst}}
      is_nil(System.find_executable("timeout")) -> {:error, :timeout_missing}
      true -> in_tmp_dir(&compile(&1, typst, timeout, model, opts))
    end
  end

  @doc "A sentence explaining an error from `render/2`, for the person downloading."
  @spec message(term()) :: String.t()
  def message({:too_many_records, count, max}),
    do:
      "This period has #{count} records, more than the #{max} one PDF can hold. " <>
        "Pick a shorter period, or download the json export."

  def message({:typst_missing, path}),
    do:
      "The PDF renderer is not installed (no typst binary at #{path}); run mix cloud.typst.install."

  def message(:timeout_missing), do: "The PDF renderer needs coreutils timeout on the server."
  def message(:timeout), do: "Rendering the PDF took too long. Pick a shorter period."
  def message({:typst_failed, _status, _output}), do: "Rendering the PDF failed."
  def message(_reason), do: "Rendering the PDF failed."

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp in_tmp_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "breakline-pdf-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir(dir), :ok <- File.chmod(dir, 0o700) do
        fun.(dir)
      else
        {:error, reason} -> {:error, {:io, reason}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp compile(dir, typst, timeout, model, opts) do
    format = opts[:format] || "pdf"
    out = if opts[:pages], do: "out-{p}.#{format}", else: "out.#{format}"
    packages = Path.join(dir, "packages")

    with :ok <- File.write(Path.join(dir, "data.json"), Jason.encode_to_iodata!(data(model))),
         {:ok, _} <- File.copy(template(), Path.join(dir, "audit.typ")),
         :ok <- File.mkdir(packages) do
      args =
        ["-k", "5", Integer.to_string(timeout), typst, "compile", "--ignore-system-fonts"] ++
          ["--root", dir, "--package-path", packages, "--package-cache-path", packages] ++
          ["--diagnostic-format", "short", "--format", format] ++
          if(opts[:pages], do: ["--pages", opts[:pages]], else: []) ++
          ["audit.typ", out]

      System.cmd("timeout", args,
        cd: dir,
        stderr_to_stdout: true,
        env: [{"SOURCE_DATE_EPOCH", Integer.to_string(model.source_date_epoch)}]
      )
      |> result(dir, out)
    else
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  # timeout exits 124 when it stopped the command, 137 when it had to kill it
  defp result({_output, status}, _dir, _out) when status in [124, 137], do: {:error, :timeout}

  defp result({_output, 0}, dir, out) do
    path = dir |> Path.join(out) |> String.replace("{p}", "*") |> Path.wildcard() |> Enum.sort()

    case path do
      [first | _] -> File.read(first)
      [] -> {:error, {:typst_failed, 0, "no output"}}
    end
  end

  defp result({output, status}, _dir, _out),
    do: {:error, {:typst_failed, status, String.slice(output, 0, 4_000)}}

  @doc "The path of the report template, `priv/typst/audit.typ`."
  @spec template() :: String.t()
  def template, do: Application.app_dir(:cloud, "priv/typst/audit.typ")

  @doc """
  The data the template reads as `data.json`: the render model with
  template-friendly keys (`ok` for `ok?`), without `source_date_epoch`.
  """
  @spec data(map()) :: map()
  def data(model) do
    %{
      title: model.title,
      tenant: model.tenant,
      period: model.period,
      generated_at: model.generated_at,
      exported_by: model.exported_by,
      coverage: model.coverage,
      verification:
        Enum.map(model.verification, fn v ->
          %{chain: v.chain, ok: v.ok?, summary: v.summary, head_hash: v.head_hash}
        end),
      sections:
        Enum.map(model.sections, fn s -> %{title: s.title, columns: s.columns, rows: s.rows} end)
    }
  end
end
