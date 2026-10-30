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
    <div class="min-h-dvh">
      {render_slot(@inner_block)}
    </div>

    <div class="fixed right-4 top-4 z-20 w-28">
      <.theme_toggle />
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
        class="tex-dots flex flex-wrap items-center gap-x-3 gap-y-3 bg-chrome px-4 py-3 text-chrome-text lg:sticky lg:top-0 lg:h-dvh lg:w-64 lg:shrink-0 lg:flex-col lg:flex-nowrap lg:items-stretch lg:gap-0 lg:overflow-y-auto lg:border-r lg:border-chrome-line lg:p-0"
      >
        <div class="order-1 mr-auto lg:order-none lg:px-6 lg:pb-9 lg:pt-8">
          <.brand />
        </div>

        <nav
          class="order-3 -mx-1 flex w-full gap-1 overflow-x-auto lg:order-none lg:mx-0 lg:flex-1 lg:flex-col lg:overflow-visible lg:px-4"
          aria-label="Principal"
        >
          <p class="mb-2 hidden px-3 font-mono text-[10px] font-medium uppercase tracking-[0.18em] text-chrome-text/60 lg:block">
            Painel
          </p>
          <.link
            :for={{key, item} <- @nav}
            id={"nav-#{key}"}
            navigate={item.path}
            aria-current={if(@active == key, do: "page")}
            class={[
              "relative flex shrink-0 items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors duration-200",
              if(@active == key,
                do: "bg-white/[0.08] text-white",
                else: "hover:bg-white/[0.05] hover:text-white"
              )
            ]}
          >
            <span
              :if={@active == key}
              class="absolute inset-y-2 -left-px w-[3px] rounded-full bg-volt lg:-left-4"
            />
            <.icon name={item.icon} class="size-[18px] shrink-0" />
            {item.label}
          </.link>
        </nav>

        <div class="order-2 flex items-center gap-3 lg:order-none lg:flex-col lg:items-stretch lg:gap-4 lg:border-t lg:border-chrome-line lg:p-5">
          <div class="w-24 lg:w-28">
            <.theme_toggle on_dark />
          </div>
          <.account_box current_scope={@current_scope} />
        </div>
      </aside>

      <div class="min-w-0 flex-1">
        <main class="mx-auto w-full max-w-6xl px-4 py-8 sm:px-8 lg:px-12 lg:py-12">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc "The heading of a panel page: a small mono caption, the title and a line under it."
  attr :caption, :string, required: true
  attr :title, :string, required: true
  slot :inner_block

  def page_header(assigns) do
    ~H"""
    <header class="reveal mb-8 lg:mb-10" style="--i: 0">
      <p class="font-mono text-[11px] font-medium uppercase tracking-[0.2em] text-ink-3">
        {@caption}
      </p>
      <h1 class="mt-2 text-3xl font-bold tracking-tight text-ink sm:text-4xl">{@title}</h1>
      <p :if={@inner_block != []} class="mt-2 max-w-2xl text-[15px] text-ink-2">
        {render_slot(@inner_block)}
      </p>
    </header>
    """
  end

  defp brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="group flex items-center gap-3" aria-label="Notifiq">
      <span class="flex size-9 items-center justify-center rounded-lg bg-volt text-[#0c1222] shadow-[0_0_0_4px_rgb(200_241_105/0.12)] transition-transform duration-300 group-hover:-rotate-6">
        <.icon name="hero-bell-alert-solid" class="size-5" />
      </span>
      <span class="leading-none">
        <span class="block text-[19px] font-bold tracking-tight text-white">Notifiq</span>
        <span class="mt-1 block font-mono text-[9px] uppercase tracking-[0.22em] text-chrome-text/70">
          mensageria
        </span>
      </span>
    </.link>
    """
  end

  attr :current_scope, :map, required: true

  defp account_box(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-1 items-center justify-end gap-3 lg:justify-between">
      <div class="hidden min-w-0 items-center gap-3 lg:flex">
        <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-white/10 font-mono text-sm font-semibold uppercase text-white">
          {String.first(@current_scope.tenant.name)}
        </span>
        <div class="min-w-0">
          <p id="tenant-name" class="truncate text-sm font-semibold text-white">
            {@current_scope.tenant.name}
          </p>
          <p id="user-email" class="truncate text-xs text-chrome-text">
            {@current_scope.user.email}
          </p>
        </div>
      </div>
      <.link
        id="logout-link"
        href={~p"/sair"}
        method="delete"
        title="Sair"
        class="inline-flex shrink-0 items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium text-chrome-text transition-colors hover:bg-white/10 hover:text-white"
      >
        <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
        <span class="lg:sr-only">Sair</span>
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
  attr :on_dark, :boolean, default: false, doc: "true when it sits on the dark sidebar"

  def theme_toggle(assigns) do
    ~H"""
    <div class={[
      "relative flex flex-row items-center rounded-full border p-0.5",
      if(@on_dark, do: "border-white/10 bg-white/[0.06]", else: "border-line bg-surface-2")
    ]}>
      <div class={[
        "absolute inset-y-0.5 left-0.5 w-[calc((100%-4px)/3)] rounded-full transition-[left] duration-300 [[data-theme=light]_&]:left-[calc(2px+(100%-4px)/3)] [[data-theme=dark]_&]:left-[calc(2px+2*(100%-4px)/3)] [[data-theme-source=system]_&]:!left-0.5",
        if(@on_dark, do: "bg-white/20", else: "bg-surface shadow-sm ring-1 ring-line")
      ]} />

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Tema do sistema"
      >
        <.icon
          name="hero-computer-desktop-micro"
          class={["size-4 opacity-70 hover:opacity-100", @on_dark && "text-white"]}
        />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Tema claro"
      >
        <.icon
          name="hero-sun-micro"
          class={["size-4 opacity-70 hover:opacity-100", @on_dark && "text-white"]}
        />
      </button>

      <button
        class="relative flex w-1/3 cursor-pointer justify-center p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Tema escuro"
      >
        <.icon
          name="hero-moon-micro"
          class={["size-4 opacity-70 hover:opacity-100", @on_dark && "text-white"]}
        />
      </button>
    </div>
    """
  end
end
