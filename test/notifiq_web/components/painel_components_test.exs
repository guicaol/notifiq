defmodule NotifiqWeb.PainelComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias NotifiqWeb.PainelComponents

  # The bubble keeps line breaks (`whitespace-pre-line`), so any whitespace the template
  # puts around the text would show up as blank lines (Spec 011, implementation notes).
  test "bubble/1 puts the text against its tags, with no whitespace of its own" do
    html = render_component(&PainelComponents.bubble/1, id: "b", text: "Olá, pedido 4321.")

    assert html =~ ~r/>Olá, pedido 4321\.<\/div>/
  end

  test "bubble/1 escapes the text and keeps its own line breaks" do
    html = render_component(&PainelComponents.bubble/1, text: "<b>oi</b>\nsegunda linha")

    refute html =~ "<b>oi</b>"
    assert html =~ "&lt;b&gt;oi&lt;/b&gt;\nsegunda linha</div>"
  end
end
