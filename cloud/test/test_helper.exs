# tests tagged :typst render real pdfs with the pinned typst cli. they run when
# the binary is installed (mix cloud.typst.install puts it at priv/bin/typst)
# and are excluded, with a note, when it is not
typst_exclude =
  if File.regular?(Cloud.Typst.path()) do
    []
  else
    IO.puts(
      "note: no typst binary at #{Cloud.Typst.path()}, excluding :typst tests " <>
        "(run mix cloud.typst.install to include them)"
    )

    [:typst]
  end

ExUnit.start(exclude: typst_exclude)
Ecto.Adapters.SQL.Sandbox.mode(Cloud.Repo, :manual)
Cloud.Signer.Static.setup!()
