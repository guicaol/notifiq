defmodule Notifiq.Channels.Provider do
  @moduledoc """
  Contrato que todo provedor de canal de saída (SMS, WhatsApp) deve implementar.

  Este é um documento normativo — faz parte da spec 004 e é referenciado por ela.
  Qualquer módulo sob `Notifiq.Channels.*` que represente um provedor DEVE implementar
  este behaviour por completo. A suíte de contrato
  (`Notifiq.Channels.ProviderContractCase`, ver spec 004 AC-6) valida isso
  automaticamente para qualquer módulo passado a ela.

  Espelha `Notifiq.Integrations.Source` (spec 002) no lado de disparo: o núcleo nunca
  conhece um provedor específico (Constitution, princípio 2). Um provider NUNCA deve
  vazar detalhes do seu provedor para fora de si mesmo — a única saída visível ao núcleo
  é `Notifiq.Channels.SendReceipt` ou um erro classificado.

  ## Classificação de erros

  O resultado de `send_message/2` decide o que o worker de disparo (spec futura) faz.
  A classe responde "a mensagem pode ter sido enviada?":

    * `:retryable` — o provedor **não** aceitou a mensagem (ex.: 429, 503 antes de
      enfileirar). Tentar de novo é seguro.
    * `:permanent` — a mensagem **nunca** será aceita (ex.: número inválido, credencial
      inválida, template recusado). Não tentar de novo.
    * `:uncertain` — **não sabemos** se foi aceita (ex.: timeout, conexão derrubada após
      o envio). Reenviar pode duplicar a mensagem; a política (reenviar ou não) é do
      worker, com apoio do `idempotency_key`.

  O `reason` é sempre um átomo estável (ex.: `:rate_limited`, `:invalid_number`); detalhes
  livres do provedor NÃO entram no erro, pois podem conter dados pessoais.
  """

  alias Notifiq.Channels.OutboundMessage
  alias Notifiq.Channels.SendReceipt

  @typedoc "Identificador atômico e estável do provedor, ex.: :twilio"
  @type provider_key :: atom()

  @typedoc "Canais de entrega suportados pela plataforma"
  @type channel :: :sms | :whatsapp

  @typedoc "Credenciais do provedor, carregadas de configuração (nunca do código-fonte)"
  @type credentials :: map()

  @type error_class :: :retryable | :permanent | :uncertain
  @type error :: {error_class(), reason :: atom()}

  @doc """
  Identificador único e estável deste provedor. Usado como chave no registry e como valor
  de `provider` em `SendReceipt` e nos registros de disparo.

  Átomo em snake_case, estável entre releases (não renomear depois de publicado).
  """
  @callback provider_key() :: provider_key()

  @doc """
  Canais que este provedor sabe entregar. Lista não vazia, subconjunto de
  `t:channel/0`. O dispatcher recusa (sem chamar o provider) mensagens de outro canal.
  """
  @callback supported_channels() :: [channel(), ...]

  @doc """
  Envia uma mensagem já renderizada.

  Recebe a mensagem validada (`to` em E.164, `body` não vazio) e as credenciais do
  provedor. O `idempotency_key` deve ser repassado ao provedor sempre que ele suportar
  deduplicação.

  Retornos:
    * `{:ok, %SendReceipt{}}` — o provedor aceitou a mensagem.
    * `{:error, {class, reason}}` — ver "Classificação de erros".

  Não deve lançar exceção para erros esperados (rede, 4xx/5xx, resposta malformada) —
  deve classificá-los. O dispatcher captura exceções e timeouts como `:uncertain`
  (spec 004, FR-9), mas isso é uma rede de segurança, não o caminho normal.

  Não deve logar `to`, `body` nem credenciais (dados pessoais e segredos).
  """
  @callback send_message(OutboundMessage.t(), credentials()) ::
              {:ok, SendReceipt.t()} | {:error, error()}
end
