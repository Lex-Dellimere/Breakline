defmodule Cloud.Signer.Static do
  @moduledoc """
  An in-memory `Cloud.Signer` for tests. `setup!/0` generates a fresh key pair
  once per test run (called from `test_helper.exs`) and keeps it in
  `:persistent_term`.
  """

  @behaviour Cloud.Signer

  @key_id "test-signer"

  @doc "Generates the key pair for this test run."
  @spec setup!() :: :ok
  def setup! do
    :persistent_term.put(__MODULE__, Breakline.Command.generate_keypair())
  end

  @impl true
  def key_id, do: @key_id

  @impl true
  def public_key, do: elem(keypair(), 0)

  @impl true
  def sign(%Breakline.Command{} = command) do
    Breakline.Command.sign(command, @key_id, elem(keypair(), 1))
  end

  defp keypair, do: :persistent_term.get(__MODULE__)
end
