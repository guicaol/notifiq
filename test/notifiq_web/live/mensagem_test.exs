defmodule NotifiqWeb.PainelLive.MensagemTest do
  # Spec 011, FR-13/14 (AC-1, AC-11).
  use NotifiqWeb.ConnCase, async: true

  import Notifiq.Test.AccountsHelpers
  import Notifiq.Test.MensageriaHelpers
  import Phoenix.LiveViewTest

  alias Notifiq.Channels.SendReceipt
  alias Notifiq.Mensageria

  defp signed_in(conn, tenant), do: log_in(conn, user!(tenant))

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp receipt,
    do: %SendReceipt{provider: "fake_sms", provider_message_id: "SM123", status: :queued}

  test "AC-1: needs a session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/entrar"}}} =
             live(conn, ~p"/painel/mensagens/#{Ecto.UUID.generate()}")
  end

  describe "a sent message" do
    setup %{conn: conn} do
      tenant = tenant!(5)
      event = event!(tenant, "evt", nil, "order_invoiced")

      {:ok, log} =
        Mensageria.reserve(
          reservation(tenant, event, %{
            recipient: "+5511999998888",
            body: "Olá Maria, seu pedido saiu."
          })
        )

      {:ok, log} = Mensageria.record_outcome(log, {:ok, receipt()})

      %{conn: signed_in(conn, tenant), tenant: tenant, log: log, event: event}
    end

    test "shows the text, the situation and the details", ctx do
      {:ok, view, html} = live(ctx.conn, ~p"/painel/mensagens/#{ctx.log.id}")

      assert text(view, "#message-body") =~ "Olá Maria, seu pedido saiu."
      assert has_element?(view, "#message-details", "Enviada")
      assert has_element?(view, "#message-details", "SMS · fake_sms")
      assert has_element?(view, "#message-details", "Pedido faturado")
      assert has_element?(view, "#message-details", "Fonte Fake")
      assert has_element?(view, "#message-details", "SM123")
      assert has_element?(view, "#message-details", "UTC")
      assert has_element?(view, "#nav-mensagens[aria-current=page]")
      assert html =~ "Mensagem"
    end

    test "FR-14: the phone is masked and the source's identifiers stay out", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/painel/mensagens/#{ctx.log.id}")

      assert html =~ "+55 ••••• 8888"
      refute html =~ "+5511999998888"
      refute html =~ "999998888"
      refute html =~ ctx.event.external_event_id
      # The stored payload names the customer; the page must not echo it.
      refute html =~ "Maria da Silva"
    end

    test "there is no problem to explain", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/painel/mensagens/#{ctx.log.id}")

      refute has_element?(view, "#message-problem")
    end

    test "lists the credit entries of this message only", ctx do
      other = reserve!(ctx.tenant)

      {:ok, view, _html} = live(ctx.conn, ~p"/painel/mensagens/#{ctx.log.id}")

      assert has_element?(view, "#message-ledger li", "Envio de mensagem")
      assert has_element?(view, "#message-ledger li", "−1")
      refute has_element?(view, "#message-ledger-empty")

      [entry] = Mensageria.list_credit_transactions_for_log(ctx.tenant.id, ctx.log.id)
      assert has_element?(view, "#ledger-#{entry.id}")
      [theirs] = Mensageria.list_credit_transactions_for_log(ctx.tenant.id, other.id)
      refute has_element?(view, "#ledger-#{theirs.id}")
    end

    test "links back to the list", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/painel/mensagens/#{ctx.log.id}")

      assert has_element?(view, "#back-to-messages[href='/painel/mensagens']")
    end
  end

  describe "a message that did not go out (AC-11)" do
    test "a permanent failure is explained in Portuguese and the refund is shown", %{conn: conn} do
      tenant = tenant!(5)
      log = reserve!(tenant)
      {:ok, log} = Mensageria.record_outcome(log, {:error, {:permanent, :invalid_number}})

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/mensagens/#{log.id}")

      assert has_element?(view, "#message-problem", "Por que não foi enviada")
      assert text(view, "#failure-reason") == "O número do cliente é inválido."
      assert text(view, "#credit-outcome") == "O crédito foi devolvido."
      assert has_element?(view, "#message-ledger li", "Estorno de envio")
      assert has_element?(view, "#message-ledger li", "+1")
      refute render(view) =~ "invalid_number"
    end

    test "a message given up on after silence is explained too", %{conn: conn} do
      tenant = tenant!(5)
      log = reserve!(tenant)
      {:ok, log} = Mensageria.give_up(log, :stale)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/mensagens/#{log.id}")

      assert text(view, "#failure-reason") =~ "parada na fila"
      assert text(view, "#credit-outcome") =~ "devolvido"
    end

    test "an unconfirmed send keeps the credit and says why", %{conn: conn} do
      tenant = tenant!(5)
      log = reserve!(tenant)
      {:ok, log} = Mensageria.record_outcome(log, {:error, {:uncertain, :timeout}})
      {:ok, log} = Mensageria.give_up(log, :uncertain_not_resent)

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/mensagens/#{log.id}")

      assert has_element?(view, "#message-problem", "Envio sem confirmação")
      assert text(view, "#credit-outcome") =~ "mantido"
      refute has_element?(view, "#message-ledger li", "Estorno")
    end

    test "a code the panel doesn't know gets a generic sentence, never the code", %{conn: conn} do
      tenant = tenant!(5)
      log = reserve!(tenant)
      {:ok, log} = Mensageria.record_outcome(log, {:error, {:permanent, :brand_new_failure}})

      {:ok, view, html} = live(signed_in(conn, tenant), ~p"/painel/mensagens/#{log.id}")

      assert text(view, "#failure-reason") == "O envio não foi concluído."
      refute html =~ "brand_new_failure"
    end

    test "a message still being retried shows the last attempt", %{conn: conn} do
      tenant = tenant!(5)
      log = reserve!(tenant)
      {:ok, log} = Mensageria.record_outcome(log, {:error, {:retryable, :rate_limited}})

      {:ok, view, _html} = live(signed_in(conn, tenant), ~p"/painel/mensagens/#{log.id}")

      assert has_element?(view, "#message-problem", "Última tentativa")
      assert text(view, "#credit-outcome") =~ "reservado"
    end
  end

  describe "not found (AC-11)" do
    defp assert_not_found(conn, path) do
      assert {:error, {:live_redirect, %{to: "/painel/mensagens"}}} = result = live(conn, path)
      {:ok, _view, html} = follow_redirect(result, conn)
      assert html =~ "Mensagem não encontrada."
    end

    test "another tenant's message looks like any missing one", %{conn: conn} do
      mine = tenant!()
      theirs = tenant!(5)
      other = reserve!(theirs, %{body: "texto secreto do outro lojista"})

      assert_not_found(signed_in(conn, mine), ~p"/painel/mensagens/#{other.id}")
    end

    test "an unknown id and a malformed one end the same way", %{conn: conn} do
      conn = signed_in(conn, tenant!())

      assert_not_found(conn, ~p"/painel/mensagens/#{Ecto.UUID.generate()}")
      assert_not_found(conn, "/painel/mensagens/not-a-uuid")
      assert_not_found(conn, "/painel/mensagens/1%27%20OR%20%271%27=%271")
    end

    test "the other tenant's text never reaches the page", %{conn: conn} do
      theirs = tenant!(5)
      other = reserve!(theirs, %{body: "texto secreto do outro lojista"})
      conn = signed_in(conn, tenant!())

      {:error, {:live_redirect, _}} = result = live(conn, ~p"/painel/mensagens/#{other.id}")
      {:ok, _view, html} = follow_redirect(result, conn)

      refute html =~ "texto secreto"
    end
  end
end
