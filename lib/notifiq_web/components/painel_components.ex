defmodule NotifiqWeb.PainelComponents do
  @moduledoc """
  Small pieces the panel screens share (Specs 010 and 011): the status badge, the chat
  bubble that previews a message, and the empty state.
  """

  use Phoenix.Component

  alias NotifiqWeb.Labels

  import NotifiqWeb.CoreComponents, only: [icon: 1]

  attr :status, :string, required: true

  def status_badge(assigns) do
    {label, tone} = Labels.message_status(assigns.status)
    assigns = assign(assigns, label: label, tone: tone)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
      case @tone do
        :ok -> "bg-ok-soft text-ok"
        :error -> "bg-bad-soft text-bad"
        :warn -> "bg-warn-soft text-warn"
        _neutral -> "bg-surface-2 text-ink-2 ring-1 ring-line"
      end
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        case @tone do
          :ok -> "bg-ok"
          :error -> "bg-bad"
          :warn -> "bg-warn"
          _neutral -> "bg-ink-3"
        end
      ]} />
      {@label}
    </span>
    """
  end

  @doc """
  A message as the customer sees it: a bubble on a quiet background. The text is an attribute,
  not a slot, because the line breaks of a slot's indentation would show up inside it.
  """
  attr :id, :string, default: nil
  attr :caption, :string, default: nil
  attr :text, :string, required: true
  attr :muted, :boolean, default: false, doc: "true for a note instead of a real message"

  def bubble(assigns) do
    ~H"""
    <div id={@id} class="rounded-2xl bg-surface-2 p-4 ring-1 ring-line">
      <p
        :if={@caption}
        class="mb-2 font-mono text-[10px] font-medium uppercase tracking-[0.16em] text-ink-3"
      >
        {@caption}
      </p>
      <%!-- `phx-no-format`: the text must touch the tags, because `whitespace-pre-line` would
           show the formatter's line breaks and indentation as blank lines in the bubble. --%>
      <div
        phx-no-format
        class={[
          "max-w-[28rem] whitespace-pre-line break-words rounded-2xl rounded-bl-md bg-surface px-4 py-3 text-[14px] leading-relaxed shadow-card ring-1 ring-line",
          if(@muted, do: "text-warn", else: "text-ink")
        ]}
      >{@text}</div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col items-center px-6 py-14 text-center", @class]}>
      <span class="flex size-11 items-center justify-center rounded-xl bg-surface-2 ring-1 ring-line">
        <.icon name={@icon} class="size-5 text-ink-3" />
      </span>
      <div class="mt-4 max-w-sm text-sm text-ink-2">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
