defmodule Cloud.Accounts do
  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Cloud.Accounts.Token
    resource Cloud.Accounts.User
  end
end
