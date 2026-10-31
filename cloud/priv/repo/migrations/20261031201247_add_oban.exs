defmodule Cloud.Repo.Migrations.AddOban do
  use Ecto.Migration

  # pinned so the migration means the same thing after an oban upgrade
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
