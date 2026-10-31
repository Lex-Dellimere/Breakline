defmodule Cloud.AuditExportPDFTest do
  use ExUnit.Case, async: true

  alias Cloud.AuditExport.PDF

  # every piece of typst syntax an audit entry could smuggle in
  @hostile [
    ~s[#read("/etc/passwd")],
    "]",
    "*x*",
    "$x$",
    "@ref",
    ~s(#import "@preview/x:0.1.0"),
    ~s[#eval("1 + 1")],
    "<lbl> `raw` _em_ = heading \\ //c /*c*/"
  ]

  @columns ["Seq", "Time (UTC)", "Actor", "Action", "Details", "Hash"]

  defp model(rows, overrides \\ %{}) do
    Map.merge(
      %{
        title: "Breakline audit export",
        tenant: "Demo clinics",
        period: "2026-10-01 00:00:00 UTC to 2026-11-01 00:00:00 UTC",
        generated_at: "2026-11-01 09:30:00 UTC",
        source_date_epoch: 1_793_525_400,
        exported_by: "admin@example.test",
        coverage: "Verification ran over each whole chain.",
        verification: [
          %{
            chain: "Cloud audit chain",
            ok?: true,
            summary: "Cloud audit chain: intact, #{length(rows)} entries, head seq 9",
            head_hash: String.duplicate("ab", 32)
          },
          %{
            chain: "Gateway chain of Parramatta clinic",
            ok?: false,
            summary:
              "Gateway chain of Parramatta clinic: broken at seq 4: a record does not match its hash (hash_mismatch)",
            head_hash: nil
          }
        ],
        sections: [
          %{title: "Cloud audit entries", columns: @columns, rows: rows},
          %{title: "Gateway audit: Parramatta clinic", columns: @columns, rows: []}
        ]
      },
      overrides
    )
  end

  defp row(i, action \\ "window.approved", details \\ "site_id: s1"),
    do: [
      Integer.to_string(i),
      "2026-10-31 12:00:00 UTC",
      "admin@example.test",
      action,
      details,
      "0123456789ab"
    ]

  defp hostile_model do
    rows =
      @hostile
      |> Enum.with_index()
      |> Enum.map(fn {text, i} -> row(i, text, "reason: " <> text) end)

    model(rows, %{tenant: "Clinic " <> ~s[#read("/etc/hostname")]})
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "pdf-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  # text compared across line wraps: any run of whitespace (and the
  # zero-width spaces the template adds to long tokens) counts as one space
  defp squash(text), do: text |> String.replace("\u200B", "") |> String.replace(~r/\s+/u, " ")

  defp unescape(html) do
    html
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  defp render_dirs, do: Path.wildcard(Path.join(System.tmp_dir!(), "breakline-pdf-*"))

  describe "with the typst binary" do
    @describetag :typst

    test "renders a pdf, and the same model always gives the same bytes" do
      model = model(Enum.map(0..40, &row/1))

      assert {:ok, first} = PDF.render(model)
      assert {:ok, second} = PDF.render(model)
      assert "%PDF-" <> _ = first
      assert first == second

      # a different generation time is a different document date
      assert {:ok, other} = PDF.render(%{model | source_date_epoch: model.source_date_epoch + 1})
      assert other != first
    end

    test "untrusted text renders literally" do
      assert {:ok, pdf} = PDF.render(hostile_model())

      # the typst-native check: export the same template and data to html with
      # typst itself and find every hostile string as text, html-escaped
      dir = tmp_dir!()
      File.write!(Path.join(dir, "data.json"), Jason.encode!(PDF.data(hostile_model())))
      File.cp!(PDF.template(), Path.join(dir, "audit.typ"))

      {_, 0} =
        System.cmd(
          Cloud.Typst.path(),
          ~w(compile --ignore-system-fonts --features html --format html --deps deps.json) ++
            ["--root", dir, "audit.typ", "out.html"],
          cd: dir,
          stderr_to_stdout: true
        )

      html = dir |> Path.join("out.html") |> File.read!() |> unescape() |> squash()

      for text <- [~s[Clinic #read("/etc/hostname")] | @hostile] do
        assert html =~ squash(text), "#{inspect(text)} not shown literally"
      end

      # nothing the data names was read: the template reads data.json, nothing else
      deps = Path.join(dir, "deps.json") |> File.read!() |> Jason.decode!()

      assert deps["inputs"] |> Enum.map(&Path.basename/1) |> Enum.sort() == [
               "audit.typ",
               "data.json"
             ]

      # and the pdf's own text, when poppler's pdftotext is around
      if pdftotext = System.find_executable("pdftotext") do
        path = Path.join(dir, "out.pdf")
        File.write!(path, pdf)
        {text, 0} = System.cmd(pdftotext, ["-raw", path, "-"])
        text = squash(text)

        for hostile <- @hostile do
          assert text =~ squash(hostile), "#{inspect(hostile)} not in the pdf text"
        end

        refute text =~ "root:x:0:0"
      end
    end

    test "renders with no network at all" do
      unshare = System.find_executable("unshare")

      if unshare && match?({_, 0}, System.cmd(unshare, ["-rn", "true"], stderr_to_stdout: true)) do
        # typst runs in a fresh network namespace with no interfaces up
        wrapper =
          script!(
            tmp_dir!(),
            "typst-offline",
            ~s(exec #{unshare} -rn "#{Cloud.Typst.path()}" "$@")
          )

        assert {:ok, "%PDF-" <> _} = PDF.render(hostile_model(), typst_path: wrapper)
      else
        IO.puts("note: unshare -rn is not available here, the no-network render was skipped")
      end
    end

    test "renders png previews of single pages" do
      model = model(Enum.map(0..80, &row/1))
      assert {:ok, <<0x89, "PNG", _::binary>>} = PDF.render(model, format: "png", pages: "2")
    end
  end

  test "the template evaluates nothing, imports nothing and reads only data.json" do
    source =
      PDF.template()
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "//"))
      |> Enum.join("\n")

    refute source =~ ~r/\beval\s*\(/
    refute source =~ ~r/#?\bimport\b/
    refute source =~ ~r/#?\binclude\b/
    refute source =~ ~r/\bplugin\s*\(/
    refute source =~ ~r/\bimage\s*\(/

    assert Regex.scan(~r/\b(read|json|csv|yaml|toml|xml|cbor)\s*\(/, source) == [
             ["json(", "json"]
           ]

    assert source =~ ~s{json("data.json")}
  end

  test "refuses a model with too many records before running typst" do
    model = model(Enum.map(1..3, &row/1))

    assert {:error, {:too_many_records, 3, 2} = reason} =
             PDF.render(model, max_records: 2, typst_path: "/nonexistent/typst")

    assert PDF.message(reason) =~ "Pick a shorter period"

    big = model(List.duplicate(row(1), PDF.max_records() + 1))
    assert {:error, {:too_many_records, 20_001, 20_000}} = PDF.render(big)
  end

  test "a missing binary is a clear error" do
    assert {:error, {:typst_missing, "/nonexistent/typst"} = reason} =
             PDF.render(model([]), typst_path: "/nonexistent/typst")

    assert PDF.message(reason) =~ "mix cloud.typst.install"

    # a file that is not executable counts as missing
    path = Path.join(tmp_dir!(), "typst")
    File.write!(path, "")
    assert {:error, {:typst_missing, ^path}} = PDF.render(model([]), typst_path: path)
  end

  test "a slow typst is killed at the timeout and its directory removed" do
    before = render_dirs()
    slow = script!(tmp_dir!(), "slow-typst", "exec sleep 30")

    {micros, result} = :timer.tc(fn -> PDF.render(model([]), typst_path: slow, timeout: 1) end)

    assert result == {:error, :timeout}
    assert micros < 10_000_000
    assert render_dirs() -- before == []
  end

  test "a failing typst returns its output and its directory is removed" do
    before = render_dirs()

    failing =
      script!(
        tmp_dir!(),
        "failing-typst",
        ~s(test -f data.json && test -f audit.typ && echo "error: boom" >&2; exit 1)
      )

    assert {:error, {:typst_failed, 1, output}} = PDF.render(model([]), typst_path: failing)
    assert output =~ "error: boom"
    assert render_dirs() -- before == []
  end

  test "typst gets the generation time as SOURCE_DATE_EPOCH and no package paths outside" do
    dir = tmp_dir!()
    log = Path.join(dir, "args")

    fake =
      script!(dir, "fake-typst", ~s"""
      echo "$SOURCE_DATE_EPOCH $*" > #{log}
      printf '%%PDF-fake' > out.pdf
      """)

    assert {:ok, "%PDF-fake"} = PDF.render(model([]), typst_path: fake)
    line = File.read!(log)
    assert line =~ ~r/^1793525400 compile --ignore-system-fonts --root (\S+) /
    [_, root] = Regex.run(~r/--root (\S+)/, line)
    assert line =~ "--package-path #{root}/packages --package-cache-path #{root}/packages"
    assert line =~ ~r/audit\.typ out\.pdf$/m
  end
end
