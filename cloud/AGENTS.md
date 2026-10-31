This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- UI components come **only** from mishka chelekom, generated into `lib/cloud_web/components/` and imported via `use CloudWeb.Components.MishkaComponents` (see the mishka_chelekom usage rules below). There is no `core_components.ex` and **no daisyUI**; do not add either, and do not render ash_authentication_phoenix's built-in components
- **Always** use mishka's `<.icon name="hero-x-mark" class="size-5" />` for hero icons, **never** use `Heroicons` modules or similar
- **Always** use mishka's form field components (`<.text_field>`, `<.email_field>`, `<.password_field>`, `<.checkbox_field>`, ...) with `field={@form[:name]}` for form inputs, inside `<.form_wrapper>` or `<.form>`
- Auth pages are our own liveviews in `lib/cloud_web/live/auth_live/`, mounted with the `live_view:` option of the ash_authentication_phoenix route macros

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- Build UI from mishka chelekom components plus plain tailwind utility classes; **never** use daisyUI
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- phoenix:ecto-start -->
## phoenix:ecto usage
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied

<!-- phoenix:ecto-end -->
<!-- phoenix:elixir-start -->
## phoenix:elixir usage
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages


<!-- phoenix:elixir-end -->
<!-- phoenix:html-start -->
## phoenix:html usage
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>

<!-- phoenix:html-end -->
<!-- phoenix:liveview-start -->
## phoenix:liveview usage
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset

<!-- phoenix:liveview-end -->
<!-- phoenix:phoenix-start -->
## phoenix:phoenix usage
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it

<!-- phoenix:phoenix-end -->
<!-- mishka_chelekom-start -->
## mishka_chelekom usage
_Mishka Chelekom is a fully featured components and UI kit library for Phoenix & Phoenix LiveView_

# Rules for Working with Mishka Chelekom

Mishka Chelekom is a UI component library for Phoenix and Phoenix LiveView. It generates fully customizable components directly into your project - no hidden dependencies, no runtime library code.

**Important**: Always read these rules and the relevant sub-rules before using Mishka Chelekom with an LLM agent.

## For LLM Agents: Fetching Additional Documentation

If you cannot find specific information in these rules (attributes, slots, examples, edge cases), **fetch the documentation from mishka.tools**:

- **Component docs**: `https://mishka.tools/chelekom/docs/{component-name}` (use hyphens, not underscores)
- **Form component docs**: `https://mishka.tools/chelekom/docs/forms/{component-name}`
- **CLI docs**: `https://mishka.tools/chelekom/docs/cli`
- **Main docs**: `https://mishka.tools/chelekom/docs`

**URL Pattern Notes**:
- Use hyphens instead of underscores: `text_field` → `text-field`
- Form components use `/forms/` prefix: `https://mishka.tools/chelekom/docs/forms/text-field`
- Non-form components: `https://mishka.tools/chelekom/docs/button`

For example:
```
Button: https://mishka.tools/chelekom/docs/button
Text Field: https://mishka.tools/chelekom/docs/forms/text-field
Device Mockup: https://mishka.tools/chelekom/docs/device-mockup
```

Always prefer the official documentation over guessing or hallucinating component attributes.

## Using with usage_rules Package

This library supports the [usage_rules](https://hexdocs.pm/usage_rules/) package (1.2 and later) for LLM agent integration.

### Setup

```elixir
# mix.exs, in deps/0
{:usage_rules, "~> 1.2", only: :dev}
```

### Configuration

The configuration lives in `project/0` of your `mix.exs`. `file` is the file the rules are written to
(`"CLAUDE.md"`, `"AGENTS.md"`, `"CURSOR.md"`, etc.) and `usage_rules` lists the packages to include:

```elixir
def project do
  [
    app: :my_app,
    # ...
    usage_rules: [
      file: "CLAUDE.md",
      usage_rules: [:mishka_chelekom]
    ]
  ]
end
```

Then sync the rules into the file:

```bash
mix usage_rules.sync
```

`:mishka_chelekom` inlines this file and the top-level sub-rules (`usage-rules/mix-tasks.md`) into
your agent's context. The packages in the file but not in the configuration are removed on each sync.

### Per-component rules

The component, headless, JS and docs rules live in sub-folders of `usage-rules/`. Name the ones you
use as `sub_rules`, relative to `usage-rules/` and without `.md`, so the agent loads only what the
project generated:

```elixir
usage_rules: [
  file: "CLAUDE.md",
  usage_rules: [
    {:mishka_chelekom, sub_rules: ["components/button", "components/modal", "docs/kit"]}
  ]
]
```

To link the files instead of inlining them, add `link: :markdown` (or `link: :at`) to the options:
`{:mishka_chelekom, sub_rules: ["components/button"], link: :markdown}`.

## Compatibility

Mishka Chelekom is designed to work **alongside any other library**:

- **Standalone**: Use only the components you need - generate just one component or all 71
- **Mix with other UI libraries**: Mishka components coexist with Phoenix CoreComponents, Surface, or any other library
- **No conflicts**: Components are generated into your codebase, not imported from a runtime dependency
- **Selective generation**: Generate `button` only, or `button,alert,modal`, or everything

```bash
# Use just one component
mix mishka.ui.gen.component button

# Use a few components
mix mishka.ui.gen.components button,alert,modal

# Use all components
mix mishka.ui.gen.components
```

## Core Principles

- Components are generated into your project's source code, giving you full control
- This library is **development-only** - it has no presence in production
- All components use Tailwind CSS 4.0+ for styling
- Components are Phoenix function components compatible with LiveView

## Requirements

- **Phoenix**: 1.8.0 or higher
- **Tailwind CSS**: 4.0 or higher
- **Elixir**: Compatible with your Phoenix version

## Quick Start

```bash
# Add to mix.exs (dev only)
{:mishka_chelekom, "~> 0.0.9", only: :dev}

# Generate a single component
mix mishka.ui.gen.component button

# Generate all components with global imports (recommended for new projects)
mix mishka.ui.gen.components --import --helpers --global --yes
```

## Sub-Rules

This package includes detailed rules for specific topics:

- **[Mix Tasks](usage-rules/mix-tasks.md)**: Complete guide for all mix tasks
- **[Components](usage-rules/components/)**: Detailed rules for each component
- **[Headless Components](usage-rules/headless/)**: Unstyled, behavior-only components (ARIA + hooks)
- **[The Kit](usage-rules/docs/kit.md)**: Reuse & restyle components with one DSL (`customize`/`from`), plus `mix mishka.ui.gen.kit`
- **[JavaScript Hooks](usage-rules/js/)**: Documentation for JavaScript hooks (Carousel, Clipboard, Collapsible, Combobox, Floating, GalleryFilter, ScrollArea, Sidebar)

For comprehensive documentation, visit: https://mishka.tools/chelekom/docs

## All Components (71 total)

### Complete List with Generation Commands

| Component | Generate Command | Documentation |
|-----------|------------------|---------------|
| `accordion` | `mix mishka.ui.gen.component accordion` | [Docs](https://mishka.tools/chelekom/docs/accordion) |
| `alert` | `mix mishka.ui.gen.component alert` | [Docs](https://mishka.tools/chelekom/docs/alert) |
| `avatar` | `mix mishka.ui.gen.component avatar` | [Docs](https://mishka.tools/chelekom/docs/avatar) |
| `badge` | `mix mishka.ui.gen.component badge` | [Docs](https://mishka.tools/chelekom/docs/badge) |
| `banner` | `mix mishka.ui.gen.component banner` | [Docs](https://mishka.tools/chelekom/docs/banner) |
| `blockquote` | `mix mishka.ui.gen.component blockquote` | [Docs](https://mishka.tools/chelekom/docs/blockquote) |
| `breadcrumb` | `mix mishka.ui.gen.component breadcrumb` | [Docs](https://mishka.tools/chelekom/docs/breadcrumb) |
| `button` | `mix mishka.ui.gen.component button` | [Docs](https://mishka.tools/chelekom/docs/button) |
| `card` | `mix mishka.ui.gen.component card` | [Docs](https://mishka.tools/chelekom/docs/card) |
| `carousel` | `mix mishka.ui.gen.component carousel` | [Docs](https://mishka.tools/chelekom/docs/carousel) |
| `chat` | `mix mishka.ui.gen.component chat` | [Docs](https://mishka.tools/chelekom/docs/chat) |
| `checkbox_card` | `mix mishka.ui.gen.component checkbox_card` | [Docs](https://mishka.tools/chelekom/docs/forms/checkbox-card) |
| `checkbox_field` | `mix mishka.ui.gen.component checkbox_field` | [Docs](https://mishka.tools/chelekom/docs/forms/checkbox-field) |
| `clipboard` | `mix mishka.ui.gen.component clipboard` | [Docs](https://mishka.tools/chelekom/docs/clipboard) |
| `collapse` | `mix mishka.ui.gen.component collapse` | [Docs](https://mishka.tools/chelekom/docs/collapse) |
| `color_field` | `mix mishka.ui.gen.component color_field` | [Docs](https://mishka.tools/chelekom/docs/forms/color-field) |
| `combobox` | `mix mishka.ui.gen.component combobox` | [Docs](https://mishka.tools/chelekom/docs/forms/combobox) |
| `date_time_field` | `mix mishka.ui.gen.component date_time_field` | [Docs](https://mishka.tools/chelekom/docs/forms/date-time-field) |
| `device_mockup` | `mix mishka.ui.gen.component device_mockup` | [Docs](https://mishka.tools/chelekom/docs/device-mockup) |
| `divider` | `mix mishka.ui.gen.component divider` | [Docs](https://mishka.tools/chelekom/docs/divider) |
| `drawer` | `mix mishka.ui.gen.component drawer` | [Docs](https://mishka.tools/chelekom/docs/drawer) |
| `dropdown` | `mix mishka.ui.gen.component dropdown` | [Docs](https://mishka.tools/chelekom/docs/dropdown) |
| `email_field` | `mix mishka.ui.gen.component email_field` | [Docs](https://mishka.tools/chelekom/docs/forms/email-field) |
| `fieldset` | `mix mishka.ui.gen.component fieldset` | [Docs](https://mishka.tools/chelekom/docs/forms/fieldset) |
| `file_field` | `mix mishka.ui.gen.component file_field` | [Docs](https://mishka.tools/chelekom/docs/forms/file-field) |
| `footer` | `mix mishka.ui.gen.component footer` | [Docs](https://mishka.tools/chelekom/docs/footer) |
| `form_wrapper` | `mix mishka.ui.gen.component form_wrapper` | [Docs](https://mishka.tools/chelekom/docs/forms) |
| `gallery` | `mix mishka.ui.gen.component gallery` | [Docs](https://mishka.tools/chelekom/docs/gallery) |
| `image` | `mix mishka.ui.gen.component image` | [Docs](https://mishka.tools/chelekom/docs/image) |
| `indicator` | `mix mishka.ui.gen.component indicator` | [Docs](https://mishka.tools/chelekom/docs/indicator) |
| `input_field` | `mix mishka.ui.gen.component input_field` | [Docs](https://mishka.tools/chelekom/docs/forms/input-field) |
| `jumbotron` | `mix mishka.ui.gen.component jumbotron` | [Docs](https://mishka.tools/chelekom/docs/jumbotron) |
| `keyboard` | `mix mishka.ui.gen.component keyboard` | [Docs](https://mishka.tools/chelekom/docs/keyboard) |
| `layout` | `mix mishka.ui.gen.component layout` | [Docs](https://mishka.tools/chelekom/docs/layout) |
| `list` | `mix mishka.ui.gen.component list` | [Docs](https://mishka.tools/chelekom/docs/list) |
| `mega_menu` | `mix mishka.ui.gen.component mega_menu` | [Docs](https://mishka.tools/chelekom/docs/mega-menu) |
| `menu` | `mix mishka.ui.gen.component menu` | [Docs](https://mishka.tools/chelekom/docs/menu) |
| `modal` | `mix mishka.ui.gen.component modal` | [Docs](https://mishka.tools/chelekom/docs/modal) |
| `native_select` | `mix mishka.ui.gen.component native_select` | [Docs](https://mishka.tools/chelekom/docs/forms/native-select) |
| `navbar` | `mix mishka.ui.gen.component navbar` | [Docs](https://mishka.tools/chelekom/docs/navbar) |
| `number_field` | `mix mishka.ui.gen.component number_field` | [Docs](https://mishka.tools/chelekom/docs/forms/number-field) |
| `overlay` | `mix mishka.ui.gen.component overlay` | [Docs](https://mishka.tools/chelekom/docs/overlay) |
| `pagination` | `mix mishka.ui.gen.component pagination` | [Docs](https://mishka.tools/chelekom/docs/pagination) |
| `password_field` | `mix mishka.ui.gen.component password_field` | [Docs](https://mishka.tools/chelekom/docs/forms/password-field) |
| `popover` | `mix mishka.ui.gen.component popover` | [Docs](https://mishka.tools/chelekom/docs/popover) |
| `progress` | `mix mishka.ui.gen.component progress` | [Docs](https://mishka.tools/chelekom/docs/progress) |
| `radio_card` | `mix mishka.ui.gen.component radio_card` | [Docs](https://mishka.tools/chelekom/docs/forms/radio-card) |
| `radio_field` | `mix mishka.ui.gen.component radio_field` | [Docs](https://mishka.tools/chelekom/docs/forms/radio-field) |
| `range_field` | `mix mishka.ui.gen.component range_field` | [Docs](https://mishka.tools/chelekom/docs/forms/range-field) |
| `rating` | `mix mishka.ui.gen.component rating` | [Docs](https://mishka.tools/chelekom/docs/rating) |
| `scroll_area` | `mix mishka.ui.gen.component scroll_area` | [Docs](https://mishka.tools/chelekom/docs/scroll-area) |
| `search_field` | `mix mishka.ui.gen.component search_field` | [Docs](https://mishka.tools/chelekom/docs/forms/search-field) |
| `sidebar` | `mix mishka.ui.gen.component sidebar` | [Docs](https://mishka.tools/chelekom/docs/sidebar) |
| `skeleton` | `mix mishka.ui.gen.component skeleton` | [Docs](https://mishka.tools/chelekom/docs/skeleton) |
| `speed_dial` | `mix mishka.ui.gen.component speed_dial` | [Docs](https://mishka.tools/chelekom/docs/speed-dial) |
| `spinner` | `mix mishka.ui.gen.component spinner` | [Docs](https://mishka.tools/chelekom/docs/spinner) |
| `stepper` | `mix mishka.ui.gen.component stepper` | [Docs](https://mishka.tools/chelekom/docs/stepper) |
| `table` | `mix mishka.ui.gen.component table` | [Docs](https://mishka.tools/chelekom/docs/table) |
| `table_content` | `mix mishka.ui.gen.component table_content` | [Docs](https://mishka.tools/chelekom/docs/table-content) |
| `tabs` | `mix mishka.ui.gen.component tabs` | [Docs](https://mishka.tools/chelekom/docs/tabs) |
| `tel_field` | `mix mishka.ui.gen.component tel_field` | [Docs](https://mishka.tools/chelekom/docs/forms/tel-field) |
| `text_field` | `mix mishka.ui.gen.component text_field` | [Docs](https://mishka.tools/chelekom/docs/forms/text-field) |
| `textarea_field` | `mix mishka.ui.gen.component textarea_field` | [Docs](https://mishka.tools/chelekom/docs/forms/textarea-field) |
| `timeline` | `mix mishka.ui.gen.component timeline` | [Docs](https://mishka.tools/chelekom/docs/timeline) |
| `toast` | `mix mishka.ui.gen.component toast` | [Docs](https://mishka.tools/chelekom/docs/toast) |
| `toggle_field` | `mix mishka.ui.gen.component toggle_field` | [Docs](https://mishka.tools/chelekom/docs/forms/toggle) |
| `tooltip` | `mix mishka.ui.gen.component tooltip` | [Docs](https://mishka.tools/chelekom/docs/tooltip) |
| `typography` | `mix mishka.ui.gen.component typography` | [Docs](https://mishka.tools/chelekom/docs/typography) |
| `url_field` | `mix mishka.ui.gen.component url_field` | [Docs](https://mishka.tools/chelekom/docs/forms/url-field) |
| `video` | `mix mishka.ui.gen.component video` | [Docs](https://mishka.tools/chelekom/docs/video) |

### Components by Category

#### Form Components (22)
`checkbox_card`, `checkbox_field`, `color_field`, `combobox`, `date_time_field`, `email_field`, `fieldset`, `file_field`, `form_wrapper`, `input_field`, `native_select`, `number_field`, `password_field`, `radio_card`, `radio_field`, `range_field`, `search_field`, `tel_field`, `text_field`, `textarea_field`, `toggle_field`, `url_field`

#### Navigation Components (10)
`breadcrumb`, `dropdown`, `mega_menu`, `menu`, `navbar`, `pagination`, `sidebar`, `speed_dial`, `stepper`, `tabs`

#### Feedback Components (10)
`alert`, `badge`, `banner`, `indicator`, `progress`, `rating`, `skeleton`, `spinner`, `toast`, `tooltip`

#### Layout Components (14)
`accordion`, `card`, `collapse`, `divider`, `drawer`, `footer`, `jumbotron`, `layout`, `modal`, `overlay`, `popover`, `table`, `table_content`, `timeline`

#### Media Components (9)
`avatar`, `carousel`, `clipboard`, `device_mockup`, `gallery`, `icon`, `image`, `scroll_area`, `video`

#### Typography Components (4)
`blockquote`, `keyboard`, `list`, `typography`

#### Specialized Components (2)
`button`, `chat`

## JavaScript Hooks (8 total)

Components that require JavaScript hooks use these files in `priv/assets/js/`:

| Hook | Used By | Purpose | Documentation |
|------|---------|---------|---------------|
| `Carousel` | carousel | Slide navigation and autoplay | [Docs](usage-rules/js/carousel.md) |
| `Clipboard` | clipboard | Copy to clipboard functionality | [Docs](usage-rules/js/clipboard.md) |
| `Collapsible` | accordion, collapse | Expand/collapse animations | [Docs](usage-rules/js/collapsible.md) |
| `Combobox` | combobox | Autocomplete and filtering | [Docs](usage-rules/js/combobox.md) |
| `Floating` | dropdown, popover, tooltip | Positioning and floating UI | [Docs](usage-rules/js/floating.md) |
| `GalleryFilter` | gallery | Image filtering | [Docs](usage-rules/js/gallery_filter.md) |
| `ScrollArea` | scroll_area | Custom scrollbar | [Docs](usage-rules/js/scroll_area.md) |
| `Sidebar` | sidebar | Sidebar minimize/expand | [Docs](usage-rules/js/sidebar.md) |

**Note**: `mishka_components.js` is the main entry point that exports all hooks.

## Component Customization Options

When generating components, you can customize:

| Option | Values |
|--------|--------|
| `--variant` | base, default, outline, transparent, subtle, shadow, inverted, bordered, gradient |
| `--color` | natural, white, dark, primary, secondary, success, warning, danger, info, silver, misc, dawn |
| `--size` | extra_small, small, medium, large, extra_large, full |
| `--rounded` | extra_small, small, medium, large, extra_large, full, none |
| `--padding` | extra_small, small, medium, large, extra_large, none |
| `--space` | extra_small, small, medium, large, extra_large |

## The Kit — Reuse & Restyle Components

The **Kit** (`MishkaChelekom.Kit`) is an opt-in Spark DSL that reuses and restyles the components you already generated — **without editing their files**. Each `customize` generates a thin wrapper that delegates to the real component.

```elixir
defmodule MyAppWeb.Kit do
  use MishkaChelekom.Kit

  customize :button do                # STYLED: color/variant/size/… (classes verbatim; write the `!`)
    color :brand, "bg-brand-500! text-white!"
    default color: :brand
  end

  customize :confirm_dialog do        # HEADLESS: style parts (full `[&_[data-part=…]]:` variant)
    from :dialog
    part :popup, "[&_[data-part=popup]]:rounded-2xl"
  end
end
```

Classes are **verbatim** — Tailwind scans them straight from your module (no safelist). The Kit is a live macro, so for **production** vendor it into your app once (it can't ride a `runtime: false` install):

```bash
mix mishka.ui.gen.kit   # copies the engine to lib/<app>/kit/, adds {:spark, "~> 2.7"}, keeps chelekom dev-only
```

Full DSL reference (all dimensions, pair rules, `from`/`base`/`default`, the vendoring flow): **[usage-rules/docs/kit.md](usage-rules/docs/kit.md)**.

## Best Practices

### DO

- Generate only the components you need
- Use `--color` and `--variant` flags to limit generated CSS
- Use `--import --helpers --global` for new projects
- Configure `priv/mishka_chelekom/config.exs` for project-wide defaults
- Read component documentation before customizing

### DON'T

- Don't install mishka_chelekom in production (use `only: :dev`)
- Don't manually edit generated components if you plan to regenerate them
- Don't use umbrella project root - navigate to specific Phoenix app
- Don't mix custom module names inconsistently

## Configuration

Create `priv/mishka_chelekom/config.exs` to set project-wide defaults:

```elixir
[
  # Only generate these colors across all components
  component_colors: ["primary", "secondary", "danger"],

  # Only generate these variants
  component_variants: ["default", "outline"],

  # Exclude components you don't need
  exclude_components: ["device_mockup", "mega_menu"],

  # Prefix all function names
  component_prefix: "ui_",

  # CSS variable overrides
  css_overrides: %{
    "--primary": "oklch(0.7 0.15 200)"
  }
]
```

## Generated Files

| Purpose | Location |
|---------|----------|
| Components | `lib/your_app_web/components/*.ex` |
| Import macro | `lib/your_app_web/components/mishka_components.ex` |
| Vendor CSS | `assets/vendor/mishka_chelekom.css` |
| Vendor JS | `assets/vendor/mishka_components.js` |
| Config | `priv/mishka_chelekom/config.exs` |

## Using Components in Templates

After generation, use components in your HEEx templates:

```heex
<%# If using --global flag, components are available everywhere %>
<.button color="primary" variant="default">Click Me</.button>

<.alert color="success">
  <:icon><.icon name="hero-check-circle" /></:icon>
  Operation completed successfully!
</.alert>

<.card>
  <.card_header>
    <.card_title>Welcome</.card_title>
  </.card_header>
  <.card_content>
    Your content here
  </.card_content>
</.card>
```

## JavaScript Hooks

Some components require JavaScript hooks (carousel, clipboard, combobox, etc.). These are automatically:

1. Copied to `assets/vendor/`
2. Imported in `assets/vendor/mishka_components.js`
3. Added to LiveSocket hooks in `assets/js/app.js`

## Opening a Component From Somewhere Else

A modal, a drawer and a dropdown render their own content closed, and each closes itself
differently: a modal is `display:none` twice over, a drawer is pushed off-screen by a transform, a
dropdown is opened by its hook. So there is no one command that opens "a component" — but there is
one place to ask.

A component that can be opened from outside itself declares the command on its **root element**:

| Attribute | Means |
|-----------|-------|
| `data-pb-open` | open this |
| `data-pb-close` | close this |
| `data-pb-toggle` | open it if closed, close it if open |

The value is an ordinary `Phoenix.LiveView.JS` command, so anything holding a reference to the
element can run it with `JS.exec/2` and needs to know nothing else about the component:

```heex
<button class="cursor-pointer" phx-click={JS.exec("data-pb-open", to: "#my-dialog")}>Open</button>
```

Declare only the verbs the component can honestly answer. A `data-pb-toggle` on something that
cannot toggle is worse than no attribute at all: the caller gets a control that looks like it works.

### If the command is a function

Name it. This is the modal, the drawer and the sidebar:

```heex
<div id={@id} data-pb-open={show_modal(@id)} data-pb-close={hide_modal(@id)}>
```

### If the command is a class

Toggle it, on whichever element the component's own selectors key on. This is the navbar, the
mega-menu and the speed dial:

```heex
<nav id={@id} data-pb-toggle={JS.toggle_class("show-nav-menu", to: "##{@id}")}>
```

### If the component is opened by a hook

A hook method is not a `JS` command and cannot be written into an attribute. Dispatch an event at
yourself and listen for it — this is the dropdown, the popover, the tooltip, the accordion and the
collapse:

```heex
<div id={@id} phx-hook="Floating" data-pb-open={JS.dispatch("chelekom:open", to: "##{@id}")}>
```

```javascript
setupOpenCommands() {
  this.boundOpenCommand = this.handleOpenCommand.bind(this);

  for (const name of ["chelekom:open", "chelekom:close", "chelekom:toggle"]) {
    this.el.addEventListener(name, this.boundOpenCommand);
  }
},

handleOpenCommand(event) {
  // `JS.dispatch` bubbles, so a dropdown inside a drawer would otherwise open the drawer too.
  if (event.target !== this.el) return;

  if (event.type === "chelekom:open") this.show();
  else if (event.type === "chelekom:close") this.hide();
  else this.toggle();
},
```

Remove the listeners in `destroyed()`. Your own component may use any event name you like — the
attribute is the contract; the event is between your template and your hook.

### For component authors shipping into MishkaCMS

The page builder reads these three attributes off a component's root and offers the component in the
"On click" target list, so an author can put a button on a page and open it with no code. It reads
the **root element only**, because that is the element carrying the class the click points at.
Declaring nothing still works; the builder falls back to inferring that the component renders closed
and to a generic show/hide, which is right for some components and does nothing for the rest.

## Updating Components

To update a component with new options:

```bash
# Regenerate with additional colors
mix mishka.ui.gen.component button --color primary,danger,success --yes
```

The `--yes` flag overwrites existing files.

## Community Components

Share or import community components:

```bash
# Import from community
mix mishka.ui.add component_custom_button

# Export your components
mix mishka.ui.export ./my_components --name my_preset
```

## Troubleshooting

### Components not styled correctly
- Ensure Tailwind CSS 4.0+ is configured
- Check that `assets/vendor/mishka_chelekom.css` is imported in `app.css`

### JavaScript hooks not working
- Verify `assets/vendor/mishka_components.js` exists
- Check `assets/js/app.js` imports MishkaComponents
- Ensure LiveSocket includes `...MishkaComponents` in hooks

### Generation fails
- Run `mix deps.get` to ensure mishka_chelekom is installed
- Check Phoenix version is 1.8+
- Ensure `lib/your_app_web/components/` directory exists

## Support

If you have questions or encounter problems, open an issue:
https://github.com/mishka-group/mishka_chelekom/issues

## Custom Components

Need a component or JavaScript functionality that isn't available in Mishka Chelekom? Request custom development:
https://mishka.tools/chelekom/custom-service

## Links

- Documentation: https://mishka.tools/chelekom/docs
- CLI Documentation: https://mishka.tools/chelekom/docs/cli
- Design System: https://mishka.tools/chelekom/docs/design-system
- Security: https://mishka.tools/chelekom/docs/security
- Roadmap: https://mishka.tools/chelekom/docs/roadmap
- GitHub: https://github.com/mishka-group/mishka_chelekom
- Issues: https://github.com/mishka-group/mishka_chelekom/issues
- Community: https://github.com/mishka-group/mishka_chelekom_community
- usage_rules Package: https://hexdocs.pm/usage_rules/

<!-- mishka_chelekom-end -->
<!-- mishka_chelekom:mix-tasks-start -->
## mishka_chelekom:mix-tasks usage
# Rules for Mishka Chelekom Mix Tasks

Mishka Chelekom provides several Mix tasks for generating, configuring, and managing UI components in Phoenix and Phoenix LiveView projects. Always read this guide before using any Mishka mix task.

**Full CLI Documentation**: https://mishka.tools/chelekom/docs/cli

> **For LLM Agents**: If you need more details about CLI options or task behavior not covered here, fetch the full documentation from the URL above.

## Prerequisites

Before using any Mishka Chelekom mix task:

- Install Mishka Chelekom in your `mix.exs` (dev only):
  ```elixir
  {:mishka_chelekom, "~> 0.0.9", only: :dev}
  ```
- Ensure Phoenix 1.8.0 or higher is installed
- Ensure Tailwind CSS 4.0 or higher is configured in `config.exs`
- Run tasks from your Phoenix project root directory (not umbrella root)
- Mishka Chelekom does NOT support umbrella projects directly - navigate to the specific Phoenix app first

**Installation Guide**: https://mishka.tools/chelekom/docs

## mix mishka.ui.gen.component

Generates a single component with customizable options.

### Basic Usage

```bash
# Generate with all default options
mix mishka.ui.gen.component button

# Generate with specific variants
mix mishka.ui.gen.component button --color primary,danger --variant default,outline

# Windows users must use quotes for multiple values
mix mishka.ui.gen.component button --color "primary,danger"
```

### Available Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--variant` | `-v` | Component variant (e.g., default, outline, shadow) |
| `--color` | `-c` | Component color (e.g., primary, danger, success) |
| `--size` | `-s` | Component size (e.g., small, medium, large) |
| `--padding` | `-p` | Component padding |
| `--space` | `-sp` | Component spacing |
| `--type` | `-t` | Component type |
| `--rounded` | `-r` | Border radius option |
| `--module` | `-m` | Custom module name |
| `--module-prefix` | - | Prefix for module names |
| `--component-prefix` | - | Prefix for function names |
| `--yes` | - | Skip all confirmation prompts |
| `--no-deps` | - | Skip generating dependent components |
| `--no-sub-config` | - | Use default settings for dependencies |
| `--no-save` | - | Don't save prefixes to config |

### Component Dependencies

Some components have **necessary** dependencies that must be generated:

```bash
# Button requires Icon component
mix mishka.ui.gen.component button
# Will prompt to also generate: icon
```

Some components have **optional** dependencies (suggested but not required):

```bash
# After generating, you'll see suggestions for optional components
```

### Best Practices

- Generate components with only the colors/variants you need to minimize CSS output
- Use `--yes` flag in CI/CD pipelines for non-interactive generation
- Use `--module-prefix` when you want namespaced components (e.g., `MishkaButton`)
- Use `--component-prefix` when you want prefixed function names (e.g., `mishka_button/1`)

### Common Patterns

```bash
# Minimal button with only primary color
mix mishka.ui.gen.component button --color primary --variant default

# Full-featured alert with all variants
mix mishka.ui.gen.component alert

# Custom module name
mix mishka.ui.gen.component modal --module MyAppWeb.Components.CustomModal

# With module prefix (creates MishkaButton module)
mix mishka.ui.gen.component button --module-prefix mishka_
```

## mix mishka.ui.gen.components

Generates multiple components at once.

### Basic Usage

```bash
# Generate ALL available components
mix mishka.ui.gen.components

# Generate specific components
mix mishka.ui.gen.components button,alert,modal

# Generate all with import file
mix mishka.ui.gen.components --import --yes

# Recommended: Generate with global imports
mix mishka.ui.gen.components --import --helpers --global --yes
```

### Available Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--import` | `-i` | Generate an import macro file |
| `--helpers` | `-h` | Include helper functions in import file |
| `--global` | `-g` | Replace Phoenix CoreComponents with Mishka components |
| `--exclude` | `-e` | Comma-separated list of components to skip |
| `--component-prefix` | - | Prefix for all function names |
| `--module-prefix` | - | Prefix for all module names |
| `--yes` | - | Skip all prompts |
| `--no-save` | - | Don't save prefixes to config |

### Import File Generation

When using `--import`, creates `lib/your_app_web/components/mishka_components.ex`:

```elixir
defmodule YourAppWeb.Components.MishkaComponents do
  @moduledoc """
  `use YourAppWeb.Components.MishkaComponents` imports the generated Mishka Chelekom components.

  `mix mishka.ui.gen.components --import` rewrites this file on every run.
  """

  defmacro __using__(_) do
    for {module, opts} <- imports() do
      quote do: import(unquote(module), unquote(opts))
    end
  end

  defp imports do
    [
      {YourAppWeb.Components.Button, only: [button: 1, button_group: 1]},
      {YourAppWeb.Components.Alert, only: [alert: 1, flash: 1, flash_group: 1]}
      # ... all components
    ]
  end
end
```

`use` injects one `import` per entry, exactly as if each were written out.

### Global Mode

Using `--global` replaces `import YourAppWeb.CoreComponents` with `use YourAppWeb.Components.MishkaComponents` in your web module's `html_helpers/0` function.

### Best Practices

- Use `--import --helpers --global --yes` for new projects
- Use `--exclude` to skip components you don't need
- Components are generated with default arguments (all colors, variants, etc.)

### Common Patterns

```bash
# New project setup (recommended)
mix mishka.ui.gen.components --import --helpers --global --yes

# Generate only form-related components
mix mishka.ui.gen.components input_field,text_field,checkbox_field,radio_field,native_select

# Exclude heavy components
mix mishka.ui.gen.components --exclude carousel,gallery,sidebar --yes

# With custom prefixes
mix mishka.ui.gen.components --module-prefix ui_ --component-prefix ui_ --yes
```

## mix mishka.ui.gen.kit

Vendors the **Kit** engine (`MishkaChelekom.Kit` — the `customize`/`from` DSL) into your app so it works in production with **no `mishka_chelekom` runtime dependency**. Unlike generated components, the Kit is a live macro (compile-time `use` + render-time runtime), so it cannot ride a `only: :dev, runtime: false` install.

### Basic Usage

```bash
# Vendor the engine under <App>.Kit into lib/<app>/kit/
mix mishka.ui.gen.kit

# Custom engine namespace
mix mishka.ui.gen.kit --module MyApp.UiKit
```

### Available Options

| Option | Description |
|--------|-------------|
| `--module` / `-m` | Base module for the vendored engine (default `<App>.Kit`) |
| `--no-deps` | Do not add `{:spark, "~> 2.7"}` to `mix.exs` |
| `--no-starter` | Do not scaffold the `<App>.Kit.Customizations` starter |
| `--yes` | Apply without prompts |

### What it generates

- `lib/<app>/kit/` — the vendored engine (namespace-rewritten to `<App>.Kit`) plus a **self-contained catalog** (no read of chelekom's `priv/`) and a `<App>.Kit.Customizations` starter — everything under one folder, with zero `mishka_chelekom` references.
- Adds `{:spark, "~> 2.7"}` to `mix.exs` via Igniter (the only runtime dependency the engine needs).

Afterward you can keep chelekom a dev-only generator: `{:mishka_chelekom, "~> 0.0.9", only: :dev, runtime: false}`. Re-run any time to refresh the engine and catalog. See **[The Kit](docs/kit.md)** for the DSL reference.

## mix mishka.ui.uninstall

Removes installed Mishka Chelekom components from your project.

### Basic Usage

```bash
# Remove a single component
mix mishka.ui.uninstall accordion

# Remove multiple components
mix mishka.ui.uninstall accordion,button,alert

# Remove all installed components (both styled and headless)
mix mishka.ui.uninstall --all

# Remove a headless component (from lib/<app>_web/components/headless/)
mix mishka.ui.uninstall accordion --headless

# Remove every installed headless component only
mix mishka.ui.uninstall --all --headless

# Preview what will be removed (no changes made)
mix mishka.ui.uninstall accordion --dry-run

# Skip confirmation prompts
mix mishka.ui.uninstall accordion --yes
```

### Available Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--all` | `-a` | Remove all installed Mishka components. Without `--headless` this removes **both** styled and headless components; add `--headless` to remove only headless ones |
| `--headless` | - | Target headless components (`components/headless/`) instead of styled ones |
| `--dry-run` | `-d` | Preview removal without making changes |
| `--yes` | `-y` | Skip confirmation prompts |
| `--force` | `-f` | Force removal even when other components depend on them |
| `--keep-js` | - | Keep JavaScript files even if unused |
| `--include-css` | - | Also remove CSS files (only with --all) |
| `--include-config` | - | Also remove config file (only with --all) |
| `--verbose` | `-V` | Show detailed output |

### Component Dependencies

Some components depend on other components (e.g., button uses icon). The uninstaller handles this:

```bash
# Interactive mode: asks if you want to also remove dependent components
mix mishka.ui.uninstall icon
# Shows: "The following components depend on 'icon': button, badge"
# Offers: cascade removal or cancel

# With --yes but no --force: blocks removal if dependencies exist
mix mishka.ui.uninstall icon --yes
# Error: Cannot remove components that other components depend on

# Force removal regardless of dependencies
mix mishka.ui.uninstall icon --yes --force
# Removes icon, warns that button and badge may have issues
```

### JavaScript Hook Management

The uninstaller intelligently handles shared JavaScript hooks:

```bash
# If accordion and collapse both use collapsible.js:
mix mishka.ui.uninstall accordion --yes
# Result: accordion.ex removed, collapsible.js KEPT (collapse still uses it)

mix mishka.ui.uninstall collapse --yes
# Result: collapse.ex removed, collapsible.js REMOVED (no component uses it)
```

Use `--keep-js` to preserve all JS files regardless:

```bash
mix mishka.ui.uninstall accordion --yes --keep-js
```

### Module Prefix Support

If you used `module_prefix` when generating components, the uninstaller finds them automatically:

```bash
# Config has: module_prefix: "mishka_"
# File is: lib/app_web/components/mishka_accordion.ex

mix mishka.ui.uninstall accordion --yes
# Correctly finds and removes mishka_accordion.ex
```

### Full Cleanup

Using `--all` completely removes all Mishka Chelekom files:

```bash
mix mishka.ui.uninstall --all --yes
```

This removes:
- All component files
- `assets/vendor/mishka_components.js`
- `assets/vendor/mishka_chelekom.css`
- `priv/mishka_chelekom/config.exs`
- Import from `mishka_components.ex`

### Common Patterns

```bash
# Preview full uninstall
mix mishka.ui.uninstall --all --dry-run

# Remove specific components, keep JS
mix mishka.ui.uninstall modal,drawer --yes --keep-js

# Complete removal
mix mishka.ui.uninstall --all --yes
```

---

## mix mishka.ui.add

Imports components from external sources (community components, custom repos).

### Basic Usage

```bash
# From official community repository
mix mishka.ui.add component_custom_button

# From GitHub URL
mix mishka.ui.add https://github.com/user/repo/blob/main/component.json

# From raw GitHub content
mix mishka.ui.add https://raw.githubusercontent.com/user/repo/main/component.json

# From GitHub Gist
mix mishka.ui.add https://gist.github.com/user/gist_id

# From local file
mix mishka.ui.add ./path/to/component.json
```

### Available Options

| Option | Description |
|--------|-------------|
| `--no-github` | Don't convert GitHub URLs to API format |
| `--headers` | Custom request headers (e.g., for private repos) |

### Security Warning

When downloading from external sources, you'll see a security prompt:

```
This is a security message, please pay attention to it!!!
You are directly requesting from an address that the Mishka team cannot validate.
```

Always verify the source before accepting external components.

### Community Repository Naming

- Components: `component_name` (e.g., `component_custom_card`)
- Presets: `preset_name` (e.g., `preset_dashboard`)
- Templates: `template_name` (e.g., `template_auth`)

## mix mishka.ui.export

Exports components to JSON format for sharing.

### Basic Usage

```bash
# Export components from a directory
mix mishka.ui.export ./my_components

# Export with Base64 encoding (for special characters)
mix mishka.ui.export ./my_components --base64

# Create a template JSON file
mix mishka.ui.export ./my_components --template

# Custom output name
mix mishka.ui.export ./my_components --name my_preset
```

### Available Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--base64` | `-b` | Encode content as Base64 |
| `--name` | `-n` | Output filename (default: template.json) |
| `--org` | `-o` | Organization type (component/preset/template) |
| `--template` | `-t` | Create empty template JSON |

### File Naming Convention

Components must follow this naming pattern:

```
component_name.eex  # Template file
component_name.exs  # Configuration file

preset_name.eex
preset_name.exs

template_name.eex
template_name.exs
```

JavaScript files only need the `.js` extension.

## mix mishka.ui.css.config

Manages CSS configuration and customization.

### Basic Usage

```bash
# Initialize configuration file
mix mishka.ui.css.config --init

# Force overwrite existing config
mix mishka.ui.css.config --init --force

# Regenerate CSS with current config
mix mishka.ui.css.config --regenerate

# Validate configuration
mix mishka.ui.css.config --validate

# Show current configuration
mix mishka.ui.css.config --show
```

### Available Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--init` | `-i` | Create sample config file |
| `--force` | `-f` | Force overwrite existing config |
| `--regenerate` | `-r` | Regenerate CSS with config |
| `--validate` | `-v` | Validate current config |
| `--show` | `-s` | Display current config |

### Configuration File

Creates `priv/mishka_chelekom/config.exs` with options:

```elixir
[
  # Exclude specific components
  exclude_components: [],

  # Limit generated options
  component_colors: [],      # e.g., ["primary", "danger"]
  component_variants: [],    # e.g., ["default", "outline"]
  component_sizes: [],       # e.g., ["small", "medium"]
  component_rounded: [],
  component_padding: [],
  component_space: [],

  # Prefix settings
  component_prefix: nil,     # e.g., "mishka_"
  module_prefix: nil,        # e.g., "Mishka"

  # CSS customization
  css_merge_strategy: :merge,  # :merge or :replace
  custom_css_path: nil,
  css_overrides: %{
    # "--primary": "#custom-color"
  }
]
```

## mix mishka.assets.install

Runs package manager install or remove commands directly in the assets directory.

### Basic Usage

```bash
# Run npm install in assets directory
mix mishka.assets.install npm

# Run yarn install
mix mishka.assets.install yarn

# Run bun install
mix mishka.assets.install bun

# Run mix bun install (using bun hex package)
mix mishka.assets.install bun mix

# Remove a package with npm
mix mishka.assets.install npm pkg remove lodash

# Remove a package with yarn
mix mishka.assets.install yarn pkg remove lodash
```

### Command Format

```bash
mix mishka.assets.install <package_manager> [pkg_type] [command] [packages...]
```

| Argument | Description |
|----------|-------------|
| `package_manager` | npm, yarn, or bun |
| `pkg_type` | `pkg` (system) or `mix` (hex package) |
| `command` | `install` or `remove` |
| `packages` | Package names (for remove command) |

### Package Manager Command Mapping

| Manager | Install Command | Remove Command |
|---------|-----------------|----------------|
| npm | `install` | `uninstall` |
| yarn | `add` | `remove` |
| bun | `install` | `remove` |

### When to Use

- Use `mishka.assets.install` for direct package manager operations
- Use `mishka.assets.deps` (below) for managing `package.json` with automatic package manager detection

---

## mix mishka.assets.deps

Manages JavaScript dependencies in `assets/package.json`.

### Basic Usage

```bash
# Add dependencies (auto-detects npm/yarn/bun)
mix mishka.assets.deps lodash,axios

# Add with specific version
mix mishka.assets.deps lodash@4.17.21

# Add as dev dependency
mix mishka.assets.deps eslint --dev

# Remove dependencies
mix mishka.assets.deps lodash --remove

# Use specific package manager
mix mishka.assets.deps lodash --npm
mix mishka.assets.deps lodash --yarn
mix mishka.assets.deps lodash --bun
mix mishka.assets.deps lodash --mix-bun
```

### Available Options

| Option | Description |
|--------|-------------|
| `--npm` | Use npm |
| `--yarn` | Use yarn |
| `--bun` | Use bun |
| `--mix-bun` | Use bun via Mix (hex package) |
| `--dev` | Add to devDependencies |
| `--remove` | Remove dependencies |
| `--yes` | Skip prompts |

### Fallback Behavior

If no package manager is found, the task will offer to install `{:bun, "~> 1.0"}` as a Mix dependency.

---

## mix mishka.mcp.server

Starts the Mishka Chelekom MCP Server as a standalone service for AI tools integration.

### Basic Usage

```bash
# HTTP transport (default), port 4003
mix mishka.mcp.server

# Custom port
mix mishka.mcp.server --port 5000

# Stdio transport — client spawns this process, no listener
mix mishka.mcp.server --transport stdio
```

### Available Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--transport` | `-t` | Transport: `http` (default) or `stdio` |
| `--port` | `-p` | HTTP port (http only, default: 4003) |

### Connecting AI Tools (HTTP)

After starting the server, connect your AI tools:

**Claude Code:**
```bash
claude mcp add --transport http mishka-chelekom http://localhost:4003/mcp
```

**Cursor/VS Code (.mcp.json):**
```json
{
  "mcpServers": {
    "mishka-chelekom": {
      "type": "http",
      "url": "http://localhost:4003/mcp"
    }
  }
}
```

### Connecting AI Tools (Stdio)

Stdio mode is meant to be **spawned by the client** — don't run it
manually. Use `mix mishka.mcp.setup --stdio` to scaffold `.mcp.json`, or
configure your client directly:

```json
{
  "mcpServers": {
    "mishka-chelekom": {
      "type": "stdio",
      "command": "mix",
      "args": ["mishka.mcp.server", "--transport", "stdio"],
      "env": {"MIX_QUIET": "1"}
    }
  }
}
```

`MIX_QUIET=1` is required — without it, Mix's `Compiling …` output
corrupts the protocol stream after code changes.

### Available MCP Tools

- `generate_component` - Generate mix command for a single component
- `generate_components` - Generate mix command for multiple components
- `get_component_info` - Get component configuration options
- `get_example` - Get HEEx code examples with usage patterns
- `get_js_hook_info` - Get JavaScript hook documentation
- `get_mix_task_info` - Get mix task documentation
- `search_components` - Search components by name or functionality
- `uninstall_component` - Generate uninstall command
- `update_config` - Update project configuration settings
- `validate_config` - Validate configuration file for errors
- `get_docs` - Fetch documentation from mishka.tools

### Available MCP Resources

- `list_components` - List all available components with categories
- `list_colors` - List color variants with CSS variables
- `list_variants` - List style variants
- `list_sizes` - List size options
- `list_spaces` - List spacing options
- `list_scripts` - List JavaScript hooks
- `list_dependencies` - List component dependencies
- `list_css_variables` - List all CSS custom properties
- `get_config` - Get current project configuration

---

## mix mishka.mcp.setup

Integrates the MCP Server directly into your Phoenix router.

### Basic Usage

```bash
# HTTP mode — patches your Phoenix router with the /mcp route
mix mishka.mcp.setup

# Stdio mode — writes .mcp.json so the client spawns the server itself
mix mishka.mcp.setup --stdio

# Custom endpoint path (http mode)
mix mishka.mcp.setup --path /api/mcp

# Enable in all environments (http mode, not just dev)
mix mishka.mcp.setup --dev-only=false

# Skip confirmation prompts
mix mishka.mcp.setup --yes
```

### Available Options

| Option | Alias | Description |
|--------|-------|-------------|
| `--stdio` | `-s` | Write `.mcp.json` instead of patching the router |
| `--path` | `-p` | Custom MCP endpoint path (http only, default: `/mcp`) |
| `--dev-only` | | Only enable in development (http only, default: true) |
| `--yes` | | Skip confirmation prompts |

### What This Task Does

**Default (HTTP):**
1. Adds the MCP route to your Phoenix router
2. Configures the route to use `Anubis.Server.Transport.StreamableHTTP.Plug`
3. Wraps it in a dev_routes condition (unless `--dev-only=false`)

**With `--stdio`:**
1. Creates (or merges into) `.mcp.json` in the project root with a
   `mishka-chelekom` stdio entry, including `MIX_QUIET=1`
2. Skips Phoenix router changes — stdio doesn't need a route
3. Preserves any other MCP servers already in `.mcp.json`

### After Setup

**HTTP:** the endpoint runs on your **Phoenix port** (default 4000):

```bash
claude mcp add --transport http mishka-chelekom http://localhost:4000/mcp
```

**Stdio:** nothing to start. Restart your MCP client; it will spawn
`mix mishka.mcp.server --transport stdio` itself on demand.

### Comparison

| Feature | `mix mishka.mcp.server` | `mix mishka.mcp.setup` | `mix mishka.mcp.setup --stdio` |
|---------|-------------------------|------------------------|--------------------------------|
| Port | 4003 (HTTP) | Phoenix port (HTTP) | None — stdio |
| Server running | Yes (foreground) | Yes (Phoenix) | No — spawned per session |
| Setup | One-time `claude mcp add` | One-time task run | One-time task run |
| Best for | Standalone projects | Phoenix apps in dev | Any project, lowest friction |

---

## Generated File Locations

| File Type | Location |
|-----------|----------|
| Components | `lib/your_app_web/components/` |
| Import macro | `lib/your_app_web/components/mishka_components.ex` |
| CSS vendor | `assets/vendor/mishka_chelekom.css` |
| JS vendor | `assets/vendor/mishka_components.js` |
| Theme CSS | Injected into `assets/css/app.css` |
| Config | `priv/mishka_chelekom/config.exs` |

## Troubleshooting

### "Phoenix is not installed"
Ensure `{:phoenix, "~> 1.8"}` is in your `mix.exs` dependencies.

### "Tailwind version not compatible"
Add to `config/config.exs`:
```elixir
config :tailwind, version: "4.0.0"
```

### "Component not found"
- Check component name spelling (use snake_case)
- Ensure you're in the correct directory
- Run `mix deps.get` to ensure mishka_chelekom is installed

### "Web module path not found"
- Ensure `lib/your_app_web/components/` directory exists
- Check your app naming follows Phoenix conventions

### Components not updating
Run with `--yes` flag to force regeneration:
```bash
mix mishka.ui.gen.component button --yes
```

<!-- mishka_chelekom:mix-tasks-end -->
<!-- ash-start -->
## ash usage
_A declarative, extensible framework for building Elixir applications._

[ash usage rules](deps/ash/usage-rules.md)
<!-- ash-end -->
<!-- ash:actions-start -->
## ash:actions usage
[ash:actions usage rules](deps/ash/usage-rules/actions.md)
<!-- ash:actions-end -->
<!-- ash:aggregates-start -->
## ash:aggregates usage
[ash:aggregates usage rules](deps/ash/usage-rules/aggregates.md)
<!-- ash:aggregates-end -->
<!-- ash:authorization-start -->
## ash:authorization usage
[ash:authorization usage rules](deps/ash/usage-rules/authorization.md)
<!-- ash:authorization-end -->
<!-- ash:calculations-start -->
## ash:calculations usage
[ash:calculations usage rules](deps/ash/usage-rules/calculations.md)
<!-- ash:calculations-end -->
<!-- ash:code_interfaces-start -->
## ash:code_interfaces usage
[ash:code_interfaces usage rules](deps/ash/usage-rules/code_interfaces.md)
<!-- ash:code_interfaces-end -->
<!-- ash:code_structure-start -->
## ash:code_structure usage
[ash:code_structure usage rules](deps/ash/usage-rules/code_structure.md)
<!-- ash:code_structure-end -->
<!-- ash:data_layers-start -->
## ash:data_layers usage
[ash:data_layers usage rules](deps/ash/usage-rules/data_layers.md)
<!-- ash:data_layers-end -->
<!-- ash:exist_expressions-start -->
## ash:exist_expressions usage
[ash:exist_expressions usage rules](deps/ash/usage-rules/exist_expressions.md)
<!-- ash:exist_expressions-end -->
<!-- ash:generating_code-start -->
## ash:generating_code usage
[ash:generating_code usage rules](deps/ash/usage-rules/generating_code.md)
<!-- ash:generating_code-end -->
<!-- ash:migrations-start -->
## ash:migrations usage
[ash:migrations usage rules](deps/ash/usage-rules/migrations.md)
<!-- ash:migrations-end -->
<!-- ash:query_filter-start -->
## ash:query_filter usage
[ash:query_filter usage rules](deps/ash/usage-rules/query_filter.md)
<!-- ash:query_filter-end -->
<!-- ash:querying_data-start -->
## ash:querying_data usage
[ash:querying_data usage rules](deps/ash/usage-rules/querying_data.md)
<!-- ash:querying_data-end -->
<!-- ash:relationships-start -->
## ash:relationships usage
[ash:relationships usage rules](deps/ash/usage-rules/relationships.md)
<!-- ash:relationships-end -->
<!-- ash:signals-start -->
## ash:signals usage
[ash:signals usage rules](deps/ash/usage-rules/signals.md)
<!-- ash:signals-end -->
<!-- ash:temporal-start -->
## ash:temporal usage
[ash:temporal usage rules](deps/ash/usage-rules/temporal.md)
<!-- ash:temporal-end -->
<!-- ash:testing-start -->
## ash:testing usage
[ash:testing usage rules](deps/ash/usage-rules/testing.md)
<!-- ash:testing-end -->
<!-- ash_ai-start -->
## ash_ai usage
_Integrated LLM features for your Ash application._

[ash_ai usage rules](deps/ash_ai/usage-rules.md)
<!-- ash_ai-end -->
<!-- ash_authentication-start -->
## ash_authentication usage
_Authentication extension for the Ash Framework._

[ash_authentication usage rules](deps/ash_authentication/usage-rules.md)
<!-- ash_authentication-end -->
<!-- ash_phoenix-start -->
## ash_phoenix usage
_Utilities for integrating Ash and Phoenix_

[ash_phoenix usage rules](deps/ash_phoenix/usage-rules.md)
<!-- ash_phoenix-end -->
<!-- ash_phoenix:best_practices-start -->
## ash_phoenix:best_practices usage
[ash_phoenix:best_practices usage rules](deps/ash_phoenix/usage-rules/best_practices.md)
<!-- ash_phoenix:best_practices-end -->
<!-- ash_phoenix:debugging_form_submissions-start -->
## ash_phoenix:debugging_form_submissions usage
[ash_phoenix:debugging_form_submissions usage rules](deps/ash_phoenix/usage-rules/debugging_form_submissions.md)
<!-- ash_phoenix:debugging_form_submissions-end -->
<!-- ash_phoenix:error_handling-start -->
## ash_phoenix:error_handling usage
[ash_phoenix:error_handling usage rules](deps/ash_phoenix/usage-rules/error_handling.md)
<!-- ash_phoenix:error_handling-end -->
<!-- ash_phoenix:form_integration-start -->
## ash_phoenix:form_integration usage
[ash_phoenix:form_integration usage rules](deps/ash_phoenix/usage-rules/form_integration.md)
<!-- ash_phoenix:form_integration-end -->
<!-- ash_phoenix:nested_forms-start -->
## ash_phoenix:nested_forms usage
[ash_phoenix:nested_forms usage rules](deps/ash_phoenix/usage-rules/nested_forms.md)
<!-- ash_phoenix:nested_forms-end -->
<!-- ash_phoenix:union_forms-start -->
## ash_phoenix:union_forms usage
[ash_phoenix:union_forms usage rules](deps/ash_phoenix/usage-rules/union_forms.md)
<!-- ash_phoenix:union_forms-end -->
<!-- ash_postgres-start -->
## ash_postgres usage
_The PostgreSQL data layer for Ash Framework_

[ash_postgres usage rules](deps/ash_postgres/usage-rules.md)
<!-- ash_postgres-end -->
<!-- ash_postgres:advanced_features-start -->
## ash_postgres:advanced_features usage
[ash_postgres:advanced_features usage rules](deps/ash_postgres/usage-rules/advanced_features.md)
<!-- ash_postgres:advanced_features-end -->
<!-- ash_postgres:best_practices-start -->
## ash_postgres:best_practices usage
[ash_postgres:best_practices usage rules](deps/ash_postgres/usage-rules/best_practices.md)
<!-- ash_postgres:best_practices-end -->
<!-- ash_postgres:check_constraints-start -->
## ash_postgres:check_constraints usage
[ash_postgres:check_constraints usage rules](deps/ash_postgres/usage-rules/check_constraints.md)
<!-- ash_postgres:check_constraints-end -->
<!-- ash_postgres:configuration-start -->
## ash_postgres:configuration usage
[ash_postgres:configuration usage rules](deps/ash_postgres/usage-rules/configuration.md)
<!-- ash_postgres:configuration-end -->
<!-- ash_postgres:custom_indexes-start -->
## ash_postgres:custom_indexes usage
[ash_postgres:custom_indexes usage rules](deps/ash_postgres/usage-rules/custom_indexes.md)
<!-- ash_postgres:custom_indexes-end -->
<!-- ash_postgres:custom_sql_statements-start -->
## ash_postgres:custom_sql_statements usage
[ash_postgres:custom_sql_statements usage rules](deps/ash_postgres/usage-rules/custom_sql_statements.md)
<!-- ash_postgres:custom_sql_statements-end -->
<!-- ash_postgres:foreign_keys-start -->
## ash_postgres:foreign_keys usage
[ash_postgres:foreign_keys usage rules](deps/ash_postgres/usage-rules/foreign_keys.md)
<!-- ash_postgres:foreign_keys-end -->
<!-- ash_postgres:migrations-start -->
## ash_postgres:migrations usage
[ash_postgres:migrations usage rules](deps/ash_postgres/usage-rules/migrations.md)
<!-- ash_postgres:migrations-end -->
<!-- ash_postgres:multitenancy-start -->
## ash_postgres:multitenancy usage
[ash_postgres:multitenancy usage rules](deps/ash_postgres/usage-rules/multitenancy.md)
<!-- ash_postgres:multitenancy-end -->
<!-- usage-rules-end -->
