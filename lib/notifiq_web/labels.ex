defmodule NotifiqWeb.Labels do
  @moduledoc """
  The words the panel uses for statuses, event types, channels, ledger reasons and failures
  (Specs 010 and 011), in one place because the same message shows up on several screens.

  Nothing here names a source or a provider (Constitution, principles 1 and 2): a provider
  appears by the key it is registered under, and a reason the panel does not know falls
  back to a generic sentence instead of leaking the raw code.
  """

  @event_types %{
    "order_created" => "Pedido criado",
    "order_invoiced" => "Pedido faturado",
    "order_shipped" => "Pedido enviado",
    "auth_code_requested" => "Código de verificação solicitado",
    "marketing_campaign_triggered" => "Campanha de marketing"
  }

  @channels %{"sms" => "SMS", "whatsapp" => "WhatsApp"}

  @message_statuses %{
    "sent" => {"Enviada", :ok},
    "pending" => {"Na fila", :neutral},
    "uncertain" => {"Verificando", :neutral},
    "failed" => {"Falhou", :error},
    "unconfirmed" => {"Sem confirmação", :warn}
  }

  @credit_reasons %{
    "dispatch" => "Envio de mensagem",
    "refund" => "Estorno de envio",
    "purchase" => "Compra de créditos",
    "adjustment" => "Ajuste"
  }

  # What the provider said, in the words a merchant can act on.
  @failure_reasons %{
    "invalid_number" => "O número do cliente é inválido.",
    "not_a_mobile_number" => "O número do cliente não é de um celular.",
    "recipient_unsubscribed" => "O cliente pediu para não receber mensagens.",
    "region_not_permitted" => "O envio para essa região não está habilitado.",
    "account_unverified" => "A conta de envio ainda não foi verificada pelo provedor.",
    "rejected" => "O provedor recusou a mensagem.",
    "rate_limited" => "O provedor pediu para diminuir o ritmo de envios.",
    "connection_failed" => "Não foi possível falar com o provedor.",
    "connection_lost" => "A conexão caiu durante o envio.",
    "timeout" => "O provedor demorou demais para responder.",
    "provider_unavailable" => "O provedor estava indisponível.",
    "invalid_response" => "A resposta do provedor não pôde ser entendida.",
    "invalid_provider_response" => "A resposta do provedor não pôde ser entendida.",
    "provider_crashed" => "O envio terminou com um erro inesperado.",
    "invalid_credentials" => "A conta de envio da plataforma não está configurada corretamente.",
    "forbidden" => "A conta de envio da plataforma não está configurada corretamente.",
    "missing_credentials" => "A conta de envio da plataforma não está configurada corretamente.",
    "unknown_provider" => "O canal escolhido no template não está mais disponível.",
    "unsupported_channel" => "O canal escolhido no template não está mais disponível.",
    "invalid_message" => "A mensagem não passou na validação do envio.",
    "stale" => "A mensagem ficou parada na fila e foi encerrada.",
    "retries_exhausted" => "As tentativas de envio acabaram.",
    "uncertain_not_resent" =>
      "Não foi possível confirmar o envio e a mensagem não foi reenviada.",
    "worker_crashed" => "O envio foi interrompido por um erro interno."
  }

  @doc "The event type in Portuguese; an unknown type is shown as it is."
  @spec event_type(String.t()) :: String.t()
  def event_type(type), do: Map.get(@event_types, type, type)

  @doc "The channel as people write it (`SMS`, `WhatsApp`)."
  @spec channel(String.t()) :: String.t()
  def channel(channel), do: Map.get(@channels, channel, String.upcase(to_string(channel)))

  @doc "The label and tone (`:ok`, `:error`, `:warn`, `:neutral`) of a message status."
  @spec message_status(String.t()) :: {String.t(), :ok | :error | :warn | :neutral}
  def message_status(status), do: Map.get(@message_statuses, status, {status, :neutral})

  @doc "The reason of a ledger entry in Portuguese."
  @spec credit_reason(String.t()) :: String.t()
  def credit_reason(reason), do: Map.get(@credit_reasons, reason, "Lançamento")

  @doc "How the template sends: the channel and the provider key, e.g. `SMS · acme`."
  @spec delivery(String.t(), String.t()) :: String.t()
  def delivery(provider, channel), do: "#{channel(channel)} · #{provider}"

  @doc """
  Why a message did not go out, for `last_error_reason` (a code the provider adapters
  produce). Unknown codes get a generic sentence and never show the code itself.
  """
  @spec failure_reason(String.t() | nil) :: String.t() | nil
  def failure_reason(nil), do: nil

  def failure_reason(reason),
    do: Map.get(@failure_reasons, reason, "O envio não foi concluído.")

  @doc "What happened to the credit of a message in `status`."
  @spec credit_outcome(String.t()) :: String.t() | nil
  def credit_outcome("failed"), do: "O crédito foi devolvido."

  def credit_outcome("unconfirmed"),
    do: "O crédito foi mantido: o envio pode ter saído e não foi possível confirmar."

  def credit_outcome(status) when status in ["pending", "uncertain"],
    do: "O crédito fica reservado até o envio terminar."

  def credit_outcome(_status), do: nil
end
