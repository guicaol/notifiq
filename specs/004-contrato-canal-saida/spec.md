# Spec 004 — Contrato de canal de saída

**Fase relacionada:** Fase de disparo — abstração de canais (espelha a Fase 4 de entrada)
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 002 (padrão de registry/behaviour que esta spec espelha)

## Goal

Prover um contrato (`Notifiq.Channels.Provider`), um registry e um dispatcher que permitam
ao núcleo de mensageria enviar uma mensagem por qualquer provedor de canal (SMS, WhatsApp)
sem conhecer nenhum provedor específico — e que traduzam toda falha de envio para uma
classificação única que o worker de disparo consiga usar para decidir entre reenviar,
desistir ou tratar como incerta.

## User story

Como plataforma, preciso enviar mensagens por provedores diferentes através de uma
interface única, para que adicionar ou trocar um provedor (ex.: Twilio por outro) não exija
alterar o núcleo — apenas escrever e registrar um novo provider — e para que o worker
saiba, sem conhecer o provedor, se reenviar uma mensagem é seguro.

## Requisitos funcionais (EARS)

- **FR-1:** Todo módulo provider DEVE implementar o behaviour `Notifiq.Channels.Provider`,
  com os callbacks `provider_key/0`, `supported_channels/0` e `send_message/2`.
- **FR-2:** O mapeamento de `provider_key` (string) para módulo provider DEVE vir de
  configuração de aplicação (`:channel_providers`), nunca de um `case`/`cond` hardcoded.
- **FR-3:** NO boot, o sistema DEVE validar cada provider configurado (módulo carregável,
  callbacks implementados, `provider_key/0` igual à chave registrada, `supported_channels/0`
  lista não vazia de canais conhecidos) e falhar o boot nomeando o provider inválido.
- **FR-4:** O sistema DEVE expor `Notifiq.Channels.Dispatcher.dispatch/2`, que recebe a chave
  do provider e uma `%OutboundMessage{}` e retorna `{:ok, %SendReceipt{}}` ou
  `{:error, {class, reason}}` com `class` em `:retryable | :permanent | :uncertain`.
- **FR-5:** QUANDO a chave não corresponder a nenhum provider registrado, `dispatch/2` DEVE
  retornar `{:error, {:permanent, :unknown_provider}}` sem chamar nenhum provider.
- **FR-6:** ANTES de chamar o provider, `dispatch/2` DEVE validar a mensagem (`to` em E.164,
  `body` não vazio e com até 4096 caracteres, `channel` conhecido, `idempotency_key` não
  vazio) e, se inválida, retornar `{:error, {:permanent, :invalid_message}}` sem chamar o
  provider.
- **FR-7:** SE o canal da mensagem não estiver em `supported_channels/0` do provider,
  `dispatch/2` DEVE retornar `{:error, {:permanent, :unsupported_channel}}` sem chamar o
  provider.
- **FR-8:** O dispatcher DEVE repassar ao provider as credenciais configuradas para aquela
  chave (`:channel_credentials`), nunca credenciais embutidas no código-fonte.
- **FR-9:** SE `send_message/2` lançar exceção, sair, exceder o timeout configurado
  (`:channel_callback_timeout`) ou retornar um valor fora do contrato, o dispatcher DEVE
  retornar `{:error, {:uncertain, reason}}` (`:provider_crashed`, `:timeout` ou
  `:invalid_provider_response`), registrar um log estruturado com `provider_key` e NÃO
  propagar a falha ao processo chamador nem afetar outros providers.
- **FR-10:** Logs e métricas do dispatcher NÃO DEVEM conter `to`, `body`, credenciais nem o
  texto de exceções do provider (dados pessoais e segredos); apenas `provider_key`, canal,
  classe e `reason`.
- **FR-11:** O dispatcher DEVE emitir o evento `:telemetry` `[:notifiq, :channels, :dispatch]`
  com `%{duration: native_time}` e metadados `%{provider, channel, outcome}`, onde `outcome`
  é `:ok` ou a classe do erro.
- **FR-12:** O sistema DEVE oferecer uma suíte de contrato reutilizável
  (`Notifiq.Channels.ProviderContractCase`) que todo provider, incluindo o do Twilio
  (spec 005), deve rodar.

## Non-goals

- Implementação de um provider concreto (Twilio é a Spec 005).
- Decidir **quando** reenviar, backoff e limite de tentativas (worker Oban — Spec 007).
- Consumo de crédito, registro de `message_logs` e idempotência de disparo (núcleo
  `Mensageria` — Spec 006). O dispatcher não deduplica: apenas repassa o `idempotency_key`.
- Renderização de templates de mensagem (o dispatcher recebe o `body` já pronto).
- Recebimento de status de entrega (callbacks do provedor); contrato próprio em spec futura.
- Escolha de qual provider/canal usar por tenant (multi-tenancy — Spec 008): o chamador
  informa a chave do provider.

## Contrato (referência normativa)

O behaviour completo está em [`contracts/provider_behaviour.ex`](contracts/provider_behaviour.ex).
Qualquer divergência entre este documento e o arquivo de contrato deve ser resolvida a favor
do arquivo de contrato — ele é a fonte executável.

Estruturas associadas:

| Struct | Campos |
|---|---|
| `Notifiq.Channels.OutboundMessage` | `tenant_id` (opcional), `channel` (`:sms \| :whatsapp`), `to` (E.164), `body`, `idempotency_key`, `metadata` (mapa livre, não enviado ao provedor) |
| `Notifiq.Channels.SendReceipt` | `provider` (string), `provider_message_id` (string), `status` (`:queued \| :sent`), `raw` (resposta original, só para auditoria) |

### Classificação de erros

| Classe | A mensagem pode ter sido enviada? | Exemplos | Reenviar |
|---|---|---|---|
| `:retryable` | Não | 429, 503 antes de enfileirar | Seguro |
| `:permanent` | Nunca será | número inválido, credencial inválida | Não |
| `:uncertain` | **Não sabemos** | timeout, conexão derrubada após envio, exceção | Pode duplicar; política do worker |

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Provider devolve `{:error, :alguma_coisa}` (fora do formato) | `{:error, {:uncertain, :invalid_provider_response}}` e log de erro |
| Provider devolve `{:error, {:retryable, "texto"}}` (reason não átomo) | Tratado como retorno inválido: `:uncertain` / `:invalid_provider_response` |
| Exceção cuja mensagem contém telefone/corpo | Log registra apenas o módulo da exceção, nunca a mensagem nem o stacktrace |
| Provider lento (acima do timeout) | Task encerrada à força; retorno `:uncertain` / `:timeout` dentro do timeout configurado |
| Dois providers configurados, um falha | O outro continua operando normalmente (isolamento) |
| `provider_key` com maiúsculas diferentes (`Twilio` vs `twilio`) | Fontes diferentes; normalizar é responsabilidade de quem configura |
| Mensagem de WhatsApp para provider que só suporta SMS | `:permanent` / `:unsupported_channel`, sem chamar o provider |

## Critérios de aceite

- **AC-1:** Um provider fake registrado é resolvido pelo registry; uma chave inexistente
  resulta em `{:error, {:permanent, :unknown_provider}}`.
- **AC-2:** `dispatch/2` com mensagem válida devolve `{:ok, %SendReceipt{}}` com
  `provider` igual à chave e `provider_message_id` preenchido.
- **AC-3:** Mensagem de canal não suportado resulta em `:permanent` / `:unsupported_channel`
  e o provider **não** é invocado.
- **AC-4:** Mensagem inválida (telefone fora de E.164, corpo vazio ou acima de 4096, canal
  desconhecido, `idempotency_key` vazio) resulta em `:permanent` / `:invalid_message` e o
  provider **não** é invocado.
- **AC-5:** Erros `:retryable`, `:permanent` e `:uncertain` devolvidos pelo provider chegam
  ao chamador com a mesma classe e o mesmo `reason`.
- **AC-6:** `ProviderContractCase` roda contra qualquer módulo e verifica os 3 callbacks e os
  tipos de retorno; todo novo provider DEVE rodá-la.
- **AC-7:** Exceção dentro de `send_message/2` resulta em `:uncertain` / `:provider_crashed`,
  um log com `provider_key` e **sem** o telefone nem o corpo da mensagem; uma chamada
  imediata a outro provider funciona normalmente.
- **AC-8:** Provider que excede o timeout resulta em `:uncertain` / `:timeout` sem travar o
  chamador.
- **AC-9:** Retorno fora do contrato resulta em `:uncertain` / `:invalid_provider_response`.
- **AC-10:** Provider mal registrado (módulo inexistente, callbacks faltando, chave
  divergente, canais inválidos) faz `Registry.validate!/0` levantar erro nomeando a chave.
- **AC-11:** O provider recebe as credenciais configuradas para a sua chave.
- **AC-12:** O evento de telemetria `[:notifiq, :channels, :dispatch]` é emitido com
  provider, canal e outcome corretos para sucesso e para cada classe de erro.
- **AC-13:** Teste de arquitetura: nenhum arquivo de `lib/` fora de `Notifiq.Integrations.*`
  menciona "bling" e nenhum fora de `Notifiq.Channels.*` menciona "twilio" (Constitution,
  princípios 1 e 2).

## Rastreabilidade

- Backlog: tarefas de disparo relativas a "contrato de provedor" e "envio por canal" (IDs
  `MSG-XXX` a vincular — o backlog não está neste repositório).
- Constitution: princípios 2, 6 e 8.
- Spec 002 (padrão espelhado) e Spec 003 (adapter de entrada, para comparação).

## Notas de implementação

- **Credenciais:** enquanto não há credenciais por tenant, vêm de
  `config :notifiq, :channel_credentials` (mapa `provider_key => credentials`, vazio por
  padrão). Quando um provider real precisar de segredo, preencher em `runtime.exs` a partir
  de variáveis de ambiente — nunca no código-fonte.
- **Timeout:** `:channel_callback_timeout` (padrão 10 000 ms; 300 ms em teste).
- **Log de falhas:** registra `provider_key`, canal e, para exceções, **apenas o módulo** da
  exceção (`error=RuntimeError`). A mensagem e o stacktrace são omitidos de propósito: um
  `FunctionClauseError` imprime os argumentos, que contêm telefone e corpo.
- **`:uncertain` é decisão de política do worker (Spec 007):** o dispatcher só classifica.
  Reenviar uma mensagem `:uncertain` pode duplicá-la; o `idempotency_key` existe para os
  provedores que deduplicam.
- **AC-13** já pegou uma violação real no momento da implementação (um comentário no
  `WebhookController` citava o Bling), corrigida.
