defmodule CloudWeb.Router do
  use CloudWeb, :router

  use AshAuthentication.Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CloudWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    plug :set_scope, scope: Cloud.Accounts.Scope, default_scope?: true
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_scope, scope: Cloud.Accounts.Scope, default_scope?: true
  end

  scope "/", CloudWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes,
      scope: Cloud.Accounts.Scope,
      default_scope: :user do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {CloudWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {CloudWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {CloudWeb.LiveUserAuth, :live_no_user}
      live "/sites", SitesLive.Index, :index
      live "/sites/:id", SitesLive.Show, :show
    end
  end

  scope "/", CloudWeb do
    pipe_through :browser

    get "/", PageController, :home
    auth_routes AuthController, Cloud.Accounts.User, path: "/auth"

    # all auth pages are our own mishka liveviews (CloudWeb.AuthLive.*);
    # none of ash_authentication_phoenix's built-in ui is rendered
    sign_out_route AuthController, "/sign-out", live_view: CloudWeb.AuthLive.SignOut

    sign_in_route live_view: CloudWeb.AuthLive.SignIn,
                  auth_routes_prefix: "/auth",
                  on_mount: [{CloudWeb.LiveUserAuth, :live_no_user}]

    reset_route live_view: CloudWeb.AuthLive.Reset,
                auth_routes_prefix: "/auth",
                on_mount: [{CloudWeb.LiveUserAuth, :live_no_user}]

    confirm_route Cloud.Accounts.User, :confirm_new_user,
      live_view: CloudWeb.AuthLive.Confirm,
      auth_routes_prefix: "/auth"

    # sign_in_route takes a single liveview, so registration and the reset
    # request get their own live session with the same auth assigns
    ash_authentication_live_session :auth_pages,
      on_mount: [{CloudWeb.LiveUserAuth, :live_no_user}] do
      live "/register", AuthLive.Register, :register
      live "/reset", AuthLive.ResetRequest, :reset_request
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", CloudWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cloud, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CloudWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:cloud, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
