defmodule Mix.Tasks.Cloud.Advisories.Poll do
  @shortdoc "Polls the CISA KEV and ACSC feeds now"

  @moduledoc """
  Polls the threat feeds now, in this process, and prints what happened.

      mix cloud.advisories.poll
      mix cloud.advisories.poll --feed kev

  `--feed` is one of `kev`, `acsc_alerts` or `acsc_advisories`; without it
  every feed is polled, KEV first. The first successful poll of a feed is
  its baseline and acts on nothing. The scheduled jobs do the same every 30
  minutes while the app runs.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [feed: :string])
    Mix.Task.run("app.start")

    results =
      case opts[:feed] do
        nil -> Cloud.Advisories.poll_all()
        name -> [{feed!(name), Cloud.Advisories.poll(feed!(name))}]
      end

    Enum.each(results, &print/1)

    if Enum.any?(results, &match?({_, {:error, _}}, &1)),
      do: Mix.raise("at least one feed failed to poll")
  end

  defp feed!(name) do
    Enum.find(Cloud.Advisories.feeds(), &(Atom.to_string(&1) == name)) ||
      Mix.raise("unknown feed #{inspect(name)}, expected one of #{inspect(Cloud.Advisories.feeds())}")
  end

  defp print({feed, {:ok, summary}}) do
    baseline = if summary.baseline?, do: " (baseline, nothing acted on)", else: ""

    Mix.shell().info(
      "#{feed}: #{summary.status}, #{summary.entries} entries, #{summary.new} new#{baseline}, " <>
        "#{length(summary.acted)} site advisories"
    )

    for acted <- summary.acted do
      Mix.shell().info("  site #{acted.site_id}: #{acted.status}")
    end
  end

  defp print({feed, {:error, reason}}) do
    Mix.shell().error("#{feed}: failed, #{inspect(reason)}")
  end
end
