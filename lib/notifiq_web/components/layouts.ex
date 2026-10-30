defmodule NotifiqWeb.Layouts do
  @moduledoc """
  Page shells (Spec 010): the panel for signed-in merchants and a plain centred shell for
  the pages before login.
  """
  use NotifiqWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @nav [
    resumo: %{label: "Resumo", icon: "hero-squares-2x2", path: "/painel"},
    integracoes: %{label: "Integrações", icon: "hero-puzzle-piece", path: "/painel/integracoes"}
  ]

  @doc """
  Renders the app layout. With a `current_scope` it is the panel (navigation, tenant,
  user, sign out); without one it is the centred shell used by the login page.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:resumo}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the navigation entry to highlight"

  slot :inner_block, required: true

  def app(%{current_scope: nil} = assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col">
      <header class="flex items-center justify-between px-4 py-5 sm:px-8">
        <.brand /> <.theme_toggle />
      </header>

      <main class="flex flex-1 items-center justify-center px-4 pb-16 sm:px-8">
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <div class="min-h-dvh lg:flex">
      <aside
        id="panel-sidebar"
        class="border-b border-zinc-200 bg-white lg:sticky lg:top-0 lg:flex lg:h-dvh lg:w-64 lg:shrink-0 lg:flex-col lg:border-b-0 lg:border-r dark:border-zinc-800 dark:bg-zinc-900"
      >
        <div class="px-4 py-4 lg:px-5 lg:py-6">
          <.brand />
        </div>

        <nav
          class="flex gap-1 overflow-x-auto px-3 pb-3 lg:flex-1 lg:flex-col lg:overflow-visible lg:pb-0"
          aria-label="Principal"
        >
          <.link
            :for={{key, item} <- @nav}
            id={"nav-#{key}"}
            navigate={item.path}
            aria-current={if(@active == key, do: "page")}
            class={[
              "group flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
              if(@active == key,
                do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-300",
                else:
                  "text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
              )
            ]}
          >
            <.icon name={item.icon} class="size-5 shrink-0" /> {item.label}
          </.link>
        </nav>

        <div class="space-y-3 border-t border-zinc-200 p-4 dark:border-zinc-800">
          <div class="w-28"><.theme_toggle /></div>
          <div><.account_box current_scope={@current_scope} /></div>
        </div>
      </aside>

      <div class="min-w-0 flex-1">
        <main class="mx-auto w-full max-w-5xl px-4 py-8 sm:px-8 lg:py-10">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  defp brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="flex items-center gap-2.5" aria-label="Notifiq">
      <span class="flex size-8 items-center justify-center rounded-lg bg-emerald-600 text-white shadow-sm">
        <.icon name="hero-bell-alert-solid" class="size-4.5" />
      </span>
      <span class="text-lg font-semibold tracking-tight">Notifiq</span>
    </.link>
    """
  end

  attr :current_scope, :map, required: true

  defp account_box(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <div class="min-w-0">
        <p id="tenant-name" class="truncate text-sm font-semibold">
          {@current_scope.tenant.name}
        </p>

        <p id="user-email" class="truncate text-xs text-zinc-500 dark:text-zinc-400">
          {@current_scope.user.email}
        </p>
      </div>

      <.link
        id="logout-link"
        href={~p"/sair"}
        method="delete"
        class="inline-flex shrink-0 items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs font-medium text-zinc-600 transition-colors hover:bg-zinc-100 hover:text-zinc-900 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
      >
        <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Sair
      </.link>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />
      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
