defmodule Notifiq.Integrations.Source do
  @moduledoc """
  Contrato que toda integração de entrada (CRM/ERP) deve implementar.

  Este é um documento normativo — faz parte da spec 002 e é referenciado por ela.
  Qualquer módulo sob `Notifiq.Integrations.*` que represente uma fonte de eventos
  DEVE implementar este behaviour por completo. A suíte de teste de contrato
  (`Notifiq.Integrations.AdapterContractTest`, ver spec 002 AC-6) valida isso
  automaticamente para qualquer módulo passado a ela.

  Um adapter NUNCA deve vazar detalhes da sua fonte para fora de si mesmo — a única
  saída visível ao núcleo é `Notifiq.Mensageria.CanonicalEvent`.
  """

  alias Notifiq.Mensageria.CanonicalEvent

  @typedoc "Identificador atômico e estável da fonte, ex.: :bling"
  @type source_key :: atom()

  @typedoc "Credenciais específicas da fonte, carregadas de `integrations.credentials`"
  @type credentials :: map()

  @typedoc "Payload bruto recebido no corpo da requisição do webhook"
  @type raw_payload :: map()

  @doc """
  Identificador único e estável desta fonte. Usado como chave no registry e como
  valor da coluna `source` em `webhook_events` e `message_logs`.

  Deve ser um átomo em snake_case, estável entre releases (não renomear depois de
  publicado — isso quebraria dados históricos e o roteamento do endpoint).
  """
  @callback source_key() :: source_key()

  @doc """
  Valida se a requisição recebida realmente se origina da fonte esperada.

  Implementações típicas: comparação de HMAC do corpo bruto contra um segredo,
  verificação de token em header, ou allowlist de IP — depende do mecanismo que a
  fonte oferece. Deve ser resistente a timing attack quando comparar segredos
  (usar `Plug.Crypto.secure_compare/2` ou equivalente).

  Recebe a `Plug.Conn` (para acessar headers e o corpo bruto) e as credenciais do
  tenant para esta integração. NÃO deve ter efeitos colaterais além de leitura.
  """
  @callback verify_authenticity(conn :: Plug.Conn.t(), credentials()) ::
              :ok | {:error, atom()}

  @doc """
  Extrai o identificador do evento usado para garantir idempotência.

  Deve ser estável: o mesmo evento reentregue pela fonte (retry de webhook) precisa
  produzir sempre o mesmo `external_event_id`. Não deve gerar um novo id por conta
  própria — se o payload não tiver identificador estável, é uma limitação da fonte
  que deve ser tratada explicitamente (ver spec do adapter concreto), não
  contornada aqui com um id sintético que mascare duplicatas reais.
  """
  @callback extract_event_id(raw_payload()) :: String.t()

  @doc """
  Identifica a conta da fonte (do lojista) que originou o evento — ex.: o `companyId` do
  Bling. O núcleo a usa para descobrir a qual tenant o evento pertence (spec 008): o
  tenant NUNCA vem do webhook, vem da integração que o lojista conectou para essa conta.

  É chamado só depois de `verify_authenticity/2` ter passado. Deve ser puro, não ter
  efeitos colaterais e nunca lançar exceção: retorne `:error` para payload sem conta.
  """
  @callback extract_account_id(raw_payload()) :: {:ok, String.t()} | :error

  @doc """
  Como a fonte aparece para o lojista no painel (spec 010): `name` é o nome da fonte e
  `account_label` o rótulo do campo em que ele informa o identificador da conta (o mesmo
  valor que `extract_account_id/1` extrai dos webhooks). `variables` lista as chaves de
  `context` que a fonte põe nos eventos (spec 011): `name` é a chave (`[a-z][a-z0-9_]*`),
  `label` como o lojista a conhece e `example` o valor usado na pré-visualização do
  template. É constante e puro; as telas do painel usam isto em vez de citar qualquer fonte
  pelo nome.
  """
  @callback metadata() :: %{
              name: String.t(),
              account_label: String.t(),
              variables: [%{name: String.t(), label: String.t(), example: String.t()}]
            }

  @doc """
  Traduz o payload bruto da fonte para o formato canônico interno, ou sinaliza que
  o evento deve ser ignorado (evento de um tipo que não gera notificação).

  Retornos possíveis:
    - `{:ok, %CanonicalEvent{}}` — evento reconhecido e traduzido com sucesso.
    - `{:ok, :ignore}` — payload válido, mas de um tipo que não deve gerar
      disparo (ex.: um status de pedido sem mensagem associada).
    - `{:error, reason}` — payload que deveria ser processável mas está malformado
      de um jeito que impede a tradução (ex.: telefone do destinatário ausente).

  Não deve lançar exceção para erros esperados de payload — reservar exceções para
  bugs genuínos. O endpoint captura exceções não tratadas (spec 002, FR-12), mas
  isso é uma rede de segurança, não o caminho normal.
  """
  @callback parse(raw_payload()) ::
              {:ok, CanonicalEvent.t()} | {:ok, :ignore} | {:error, atom()}
end
