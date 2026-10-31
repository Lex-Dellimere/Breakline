defmodule Cloud.Signer.FileTest do
  use ExUnit.Case, async: false

  alias Breakline.Command

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "signer_ed25519.json")
    previous = Application.get_env(:cloud, Cloud.Signer.File)
    Application.put_env(:cloud, Cloud.Signer.File, path: path)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: Application.put_env(:cloud, Cloud.Signer.File, previous),
        else: Application.delete_env(:cloud, Cloud.Signer.File)
    end)

    %{path: path, dir: dir}
  end

  test "keygen writes a 0600 key file the file signer can sign with", %{path: path, dir: dir} do
    Mix.Tasks.Cloud.Signer.Keygen.run([])

    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:ok, %{"key_id" => "cloud-" <> _ = key_id, "public_key" => pub, "private_key" => _}} =
             path |> File.read!() |> JSON.decode()

    # the public half alone, in the format the gateway's dev config reads
    assert {:ok, %{"key_id" => ^key_id, "public_key" => ^pub} = public} =
             dir |> Path.join("signer_ed25519.public.json") |> File.read!() |> JSON.decode()

    refute Map.has_key?(public, "private_key")

    assert Cloud.Signer.File.key_id() == key_id
    assert Base.url_encode64(Cloud.Signer.File.public_key(), padding: false) == pub

    command =
      Command.new!(
        type: "policy",
        site_id: "s1",
        policy_version: 1,
        payload: %{},
        ttl_seconds: 60
      )

    wire = Cloud.Signer.File.sign(command)

    verifier =
      Command.Verifier.new(
        site_id: "s1",
        public_keys: %{key_id => Base.url_decode64!(pub, padding: false)}
      )

    assert {:ok, _, _} = Command.verify(wire, verifier, DateTime.utc_now())

    assert_raise Mix.Error, ~r/already exists/, fn -> Mix.Tasks.Cloud.Signer.Keygen.run([]) end
    Mix.Tasks.Cloud.Signer.Keygen.run(["--force"])
    assert {:ok, %{key_id: "cloud-" <> _}} = Cloud.Signer.File.read(path)
  end

  test "rejects a key file whose public key does not match", %{path: path} do
    {pub, _} = Command.generate_keypair()
    {_, priv} = Command.generate_keypair()
    b64 = &Base.url_encode64(&1, padding: false)

    File.write!(
      path,
      JSON.encode!(%{"key_id" => "k", "public_key" => b64.(pub), "private_key" => b64.(priv)})
    )

    assert {:error, :key_mismatch} = Cloud.Signer.File.read(path)
    assert {:error, :enoent} = Cloud.Signer.File.read(path <> ".missing")
  end
end
