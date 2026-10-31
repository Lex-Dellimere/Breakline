defmodule Cloud.Typst do
  @moduledoc """
  The pinned Typst CLI that renders audit PDFs (D38): its release, the
  checksums it is verified against, and where the binary lives.

  Typst runs as a separate OS process (`Cloud.AuditExport.PDF`), never as a
  NIF. The binary is installed by `mix cloud.typst.install` from the
  official static release asset. Typst publishes no checksum file of its
  own, so the archive checksum pinned here is the SHA-256 digest GitHub
  publishes for the release asset, which matched the checksum of the
  downloaded archive when it was pinned. The binary checksum was computed
  from the binary in that archive.

  The binary path is `:cloud, :typst_path`: `priv/bin/typst` under the app in
  dev and test, `TYPST_PATH` in production (`config/runtime.exs`).
  """

  @version "0.15.1"
  @asset "typst-x86_64-unknown-linux-musl.tar.xz"
  @archive_sha256 "a6d077d0a95eed5a2eba715b2dae06be954f624ccbf85758a03f389ded33118c"
  @binary_sha256 "29273eaa04f6d00edd0c2bec578f565fc9c65be856bfbffc894567c68ed0b237"

  @doc "The pinned Typst version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The release asset's file name."
  @spec asset() :: String.t()
  def asset, do: @asset

  @doc "The release asset's download url."
  @spec url() :: String.t()
  def url, do: "https://github.com/typst/typst/releases/download/v#{@version}/#{@asset}"

  @doc "The pinned SHA-256 of the release archive, lowercase hex."
  @spec archive_sha256() :: String.t()
  def archive_sha256, do: @archive_sha256

  @doc "The pinned SHA-256 of the `typst` binary inside the archive, lowercase hex."
  @spec binary_sha256() :: String.t()
  def binary_sha256, do: @binary_sha256

  @doc "The path of the binary inside the archive."
  @spec archive_member() :: String.t()
  def archive_member, do: String.replace_suffix(@asset, ".tar.xz", "") <> "/typst"

  @doc """
  The configured binary path (`:cloud, :typst_path`), expanded. A relative
  path is taken from the app's directory, so the dev and test default
  `priv/bin/typst` works whatever the current directory.
  """
  @spec path() :: String.t()
  def path do
    case Application.get_env(:cloud, :typst_path) do
      nil -> Application.app_dir(:cloud, "priv/bin/typst")
      path -> Path.expand(path, File.cwd!())
    end
  end

  @doc """
  Whether the binary at `path` is the pinned one: `:pinned`, `:missing`, or
  `{:other, sha256}`.
  """
  @spec installed_status(String.t()) :: :pinned | :missing | {:other, String.t()}
  def installed_status(path) do
    if File.regular?(path) do
      case file_sha256(path) do
        @binary_sha256 -> :pinned
        sha -> {:other, sha}
      end
    else
      :missing
    end
  end

  @doc "The SHA-256 of a file, lowercase hex."
  @spec file_sha256(String.t()) :: String.t()
  def file_sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
