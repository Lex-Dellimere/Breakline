defmodule Mix.Tasks.Breakline.Audit.Verify do
  @shortdoc "Re-verifies the hash chains in a Breakline audit export"

  @moduledoc """
  Re-verifies every chain segment in an audit export file offline, with
  `Breakline.AuditLog` (see `Breakline.AuditExport` for what is checked and
  how a period that starts mid-chain is handled).

      mix breakline.audit.verify breakline-audit-acme-2026-10-01-2026-10-31.json

  Prints one line per chain. Exits with status 0 when every chain is intact,
  1 when one is broken (the first break is printed last), and 2 when the
  file cannot be read or is not an export.
  """

  use Mix.Task

  alias Breakline.AuditExport

  @impl true
  def run([path]) do
    with {:ok, body} <- read(path),
         {:ok, export} <- decode(body) do
      case AuditExport.verify(export) do
        {:ok, results} ->
          Enum.each(results, &Mix.shell().info(AuditExport.describe(&1)))
          Mix.shell().info("all chains intact")

        {:error, :not_an_export} ->
          fail(2, "#{path} is not a #{AuditExport.format()} file")

        {:error, results} ->
          Enum.each(results, &Mix.shell().info(AuditExport.describe(&1)))
          first = Enum.find(results, &(&1.result != :ok))
          fail(1, "first break: " <> AuditExport.describe(first))
      end
    end
  end

  def run(_args), do: fail(2, "usage: mix breakline.audit.verify <export.json>")

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> fail(2, "cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, export} -> {:ok, export}
      {:error, _} -> fail(2, "the file is not valid json")
    end
  end

  defp fail(status, message) do
    Mix.shell().error(message)
    exit({:shutdown, status})
  end
end
