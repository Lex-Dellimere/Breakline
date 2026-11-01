defmodule Mix.Tasks.Gateway.Enroll do
  @shortdoc "Enrols this dev gateway with a code from the cloud's site page"

  @moduledoc """
  Runs `Gateway.Enroll` from a checkout, the dev twin of
  `sudo breakline-gateway enroll` on a box:

      mix gateway.enroll <cloud_url> <code> --ca-sha256 <hex> [--data-dir tmp/dev_enrolled]

  The identity and the enrolment go to `--data-dir` (default
  `tmp/dev_enrolled`, git-ignored). When `tmp/dev_enrolled/enrollment.json`
  exists, `config/dev.exs` runs the gateway as that enrolled site: its site
  id, the cloud's signing key and the uplink from the enrolment.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: [ca_sha256: :string, data_dir: :string])

    {url, code, pin} =
      case {argv, opts[:ca_sha256]} do
        {[url, code], pin} when is_binary(pin) ->
          {url, code, pin}

        _ ->
          Mix.raise(
            "usage: mix gateway.enroll <cloud_url> <code> --ca-sha256 <hex> [--data-dir DIR]"
          )
      end

    data_dir = opts |> Keyword.get(:data_dir, "tmp/dev_enrolled") |> Path.expand()
    {:ok, _} = Application.ensure_all_started([:crypto, :public_key, :ssl])

    case Gateway.Enroll.run(url, code, pin, data_dir) do
      {:ok, e} ->
        Mix.shell().info(
          "enrolled: site #{e["site_id"]}, gateway certificate #{e["fingerprint"]}, in #{data_dir}"
        )

      {:error, reason} ->
        Mix.raise("enrolment failed: " <> Gateway.Enroll.format_error(reason))
    end
  end
end
