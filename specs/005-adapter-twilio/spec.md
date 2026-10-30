# Spec 005 — Adapter do Twilio (SMS)

**Fase relacionada:** Fase de disparo — primeiro provider de canal
**Status:** Implementada (2026-10-30) — apenas SMS; ver pontos em aberto
**Depende de:** Spec 004 (contrato `Notifiq.Channels.Provider`)

## Goal

Implementar `Notifiq.Channels.Provider` para o Twilio, enviando SMS pela Messages API e
traduzindo cada resposta ou falha para a classificação da Spec 004
(`:retryable | :permanent | :uncertain`), de modo que o worker de disparo nunca precise
conhecer o Twilio.

## User story

Como plataforma, quero enviar SMS pelo Twilio através do contrato de canal, para que o
lojista notifique seu cliente e para que trocar de provedor no futuro não exija alterar o
núcleo.

## Verificado na documentação oficial do Twilio (2026-10-30)

Fontes: `twilio.com/docs/messaging/api/message-resource`, `twilio.com/docs/api/errors` (e
as páginas dos erros 20429, 63016 e 17534), `twilio.com/docs/usage/twilios-response`.

| Item | O que a documentação diz |
|---|---|
| Endpoint | `POST https://api.twilio.com/2010-04-01/Accounts/{AccountSid}/Messages.json`; `AccountSid` casa `^AC[0-9a-fA-F]{32}$` |
| Corpo | `application/x-www-form-urlencoded` |
| Autenticação | HTTP Basic: `AccountSid:AuthToken` ou `ApiKeySid:ApiKeySecret` |
| Parâmetros | `To` (E.164), remetente (`From` **ou** `MessagingServiceSid`), conteúdo (`Body`, `MediaUrl` ou `ContentSid`) |
| Resposta | objeto com `sid` (prefixo `SM`/`MM`) e `status`; inicial `queued` (`accepted` quando só `MessagingServiceSid`) |
| Erro | JSON `{status, message, code?, more_info?}`; `code` e `more_info` aparecem só às vezes |
| HTTP 401 | credenciais ausentes ou inválidas |
| HTTP 429 / `20429` | limite de concorrência; a requisição **não foi processada** e é "segura de reenviar após backoff"; não há `Retry-After` documentado |
| HTTP 500 / 503 | erro interno / indisponibilidade temporária |
| `21211`, `21614`, `21610`, `21408` | `To` inválido; não é celular; destinatário descadastrado; região sem permissão |
| `21608` | conta trial/sem perfil de compliance para número não verificado |
| `63016` (WhatsApp) | mensagem de texto livre fora da janela de 24 h; fora dela só com template aprovado (`ContentSid`) |

### Pontos em aberto (não confirmados — não assumir)

1. **Idempotência da Messages API:** a documentação não diz que ela aceite um token de
   idempotência (só cita um `Idempotency-Key` genérico, sem dizer onde vale). Esta spec
   **não envia** header de idempotência. Consequência: um envio `:uncertain` reenviado pode
   duplicar o SMS; a política é do worker (Spec 007).
2. **HTTP 5xx:** a documentação não diz se uma requisição que recebeu 500/503 foi processada.
   Por prudência são classificados como `:uncertain`, não `:retryable`.
3. **Código HTTP de sucesso:** a página não o declara; aceitamos qualquer 2xx com `sid`.

## Requisitos funcionais (EARS)

- **FR-1:** `Notifiq.Channels.Twilio` DEVE implementar `Notifiq.Channels.Provider` por
  completo (validado pela suíte de contrato da Spec 004, AC-6).
- **FR-2:** `provider_key/0` DEVE retornar `:twilio` e `supported_channels/0` DEVE retornar
  `[:sms]`. WhatsApp está fora do escopo (ver Non-goals).
- **FR-3:** `send_message/2` DEVE enviar `POST` form-encoded para a Messages API da conta,
  com `To` e `Body` da mensagem e o remetente configurado: `MessagingServiceSid` quando
  configurado, senão `From`.
- **FR-4:** A autenticação DEVE ser HTTP Basic com `account_sid`/`auth_token`, ou com
  `api_key_sid`/`api_key_secret` quando presentes (a conta continua no caminho da URL).
- **FR-5:** SE faltar credencial (conta, token/secret ou remetente), DEVE retornar
  `{:error, {:permanent, :missing_credentials}}` sem fazer requisição.
- **FR-6:** QUANDO a resposta for 2xx com `sid`, DEVE retornar `{:ok, %SendReceipt{}}` com
  `provider: "twilio"`, `provider_message_id` igual ao `sid` e `status` mapeado
  (`queued`/`accepted`/`scheduled` → `:queued`; `sending`/`sent` → `:sent`).
- **FR-7:** O `raw` do recibo DEVE conter apenas campos não pessoais da resposta (`sid`,
  `status`, `num_segments`, `date_created`, `messaging_service_sid`, `error_code`,
  `error_message`), nunca `to`, `from` ou `body`.
- **FR-8:** DEVE classificar as falhas conforme a tabela "Classificação de erros" abaixo.
- **FR-9:** NÃO DEVE reenviar a requisição por conta própria (`retry: false`): um POST
  reenviado automaticamente pode duplicar o SMS. Reenvio é decisão do worker.
- **FR-10:** O tempo máximo da requisição (`receive_timeout`) DEVE ser menor que o timeout
  do dispatcher, para que o provider devolva um erro classificado antes do dispatcher
  abortá-lo.
- **FR-11:** O provider NÃO DEVE logar `to`, `body`, `account_sid`, `auth_token` nem o
  corpo da resposta de erro; apenas status HTTP e `code` numérico do Twilio.
- **FR-12:** As credenciais DEVEM vir de variáveis de ambiente lidas em `config/runtime.exs`
  (`TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_SMS_FROM` ou
  `TWILIO_MESSAGING_SERVICE_SID`); em produção a ausência de qualquer uma falha o boot
  nomeando a variável.

## Classificação de erros (FR-8)

| Situação | Classe | `reason` |
|---|---|---|
| HTTP 429 (`20429`) | `:retryable` | `:rate_limited` |
| Falha de conexão antes de enviar (`econnrefused`, `nxdomain`) | `:retryable` | `:connection_failed` |
| Timeout ou conexão interrompida depois de enviar | `:uncertain` | `:timeout` / `:connection_lost` |
| HTTP 500, 502, 503, 504 | `:uncertain` | `:provider_unavailable` |
| HTTP 2xx sem `sid` ou status desconhecido | `:uncertain` | `:invalid_response` |
| HTTP 401 | `:permanent` | `:invalid_credentials` |
| HTTP 403 | `:permanent` | `:forbidden` |
| `21211` | `:permanent` | `:invalid_number` |
| `21614` | `:permanent` | `:not_a_mobile_number` |
| `21610` | `:permanent` | `:recipient_unsubscribed` |
| `21408` | `:permanent` | `:region_not_permitted` |
| `21608` | `:permanent` | `:account_unverified` |
| Qualquer outro 4xx, ou status `failed`/`undelivered`/`canceled` | `:permanent` | `:rejected` |

## Non-goals

- **WhatsApp.** Mensagens iniciadas pelo negócio fora da janela de 24 h exigem template
  aprovado (`ContentSid` + variáveis), e `OutboundMessage` só carrega texto já renderizado.
  Declarar `:whatsapp` agora faria quase todo envio falhar com `63016`. Fica para uma spec
  própria que estenda o contrato com template.
- Receber callbacks de status de entrega (`StatusCallback`), MMS e agendamento.
- Decidir reenvio, backoff e limites (Spec 007), crédito e `message_logs` (Spec 006).
- Credenciais por tenant (Spec 008): por enquanto são globais, da plataforma.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| `MessagingServiceSid` e `From` configurados | `MessagingServiceSid` prevalece; `From` não é enviado |
| Resposta de erro que não é JSON (ex.: HTML de um gateway 502) | Classificada só pelo status HTTP |
| Erro 400 com `code` desconhecido | `:permanent` / `:rejected` |
| Resposta de erro contendo o número do destinatário na `message` | O texto nunca é copiado para o erro nem para logs |
| `receive_timeout` excedido | `:uncertain` / `:timeout`, sem retry interno |
| Credenciais vazias (`""`) | Tratadas como ausentes |

## Critérios de aceite

- **AC-1:** O provider passa pela suíte de contrato da Spec 004 (`ProviderContractCase`).
- **AC-2:** A requisição enviada tem método `POST`, caminho
  `/2010-04-01/Accounts/{sid}/Messages.json`, `content-type` form, `Authorization: Basic`
  correto, e os parâmetros `To`, `Body` e `From` (ou `MessagingServiceSid`, que prevalece).
- **AC-3:** Resposta 201 com `sid` e `status: "queued"` resulta em recibo com
  `provider_message_id` igual ao `sid`; o `raw` não contém `to`, `from` nem `body`.
- **AC-4:** Cada linha da tabela de classificação é coberta por um teste.
- **AC-5:** `Req.Test.transport_error` com `:econnrefused` resulta em `:retryable`; com
  `:timeout` e `:closed`, em `:uncertain`.
- **AC-6:** Credenciais ausentes ou vazias resultam em `:permanent` / `:missing_credentials`
  e zero requisições.
- **AC-7:** Com `api_key_sid`/`api_key_secret`, o Basic usa a chave, e a URL usa a conta.
- **AC-8:** Mesmo diante de 500 ou 429, exatamente **uma** requisição é feita.
- **AC-9:** Pelo `Dispatcher`, a chave `"twilio"` resolve este provider; uma mensagem de
  WhatsApp resulta em `:permanent` / `:unsupported_channel` sem requisição.
- **AC-10:** Nenhum log gerado nos cenários de erro contém telefone, corpo, `auth_token` nem
  `account_sid`.
- **AC-11:** Nenhum header de idempotência é enviado (ponto em aberto 1).
- **AC-12:** Nenhum teste faz requisição de rede real (`Req.Test` substitui o transporte).
- **AC-13:** O teste de arquitetura da Spec 004 continua passando: "twilio" só aparece em
  `Notifiq.Channels.*`.

## Rastreabilidade

- Backlog: tarefas de disparo relativas a "integração Twilio" (IDs `MSG-XXX` a vincular).
- Constitution: princípios 2 e 6; qualidade: nenhum teste chama API real.
- Spec 004 (contrato) e Spec 003 (adapter de entrada, padrão espelhado).

## Notas de implementação

- **Testes sem rede:** `Req.Test` (já presente no Req 0.6) substitui o transporte; é o
  equivalente a Bypass/Mox exigido pela constitution, sem dependência nova. O stub padrão
  está em `test/support/twilio_stub.ex`.
- **Corpo decodificado manualmente (`decode_body: false`):** o teste do AC-4 pegou um bug
  real — um corpo de erro que não é JSON (ex.: HTML de gateway 502) fazia o Req levantar
  `Jason.DecodeError`, e o status HTTP se perdia (virava `:connection_lost`). Agora o
  corpo é decodificado de forma tolerante e a classificação usa o status.
- **Credenciais:** globais da plataforma, em `config :notifiq, :channel_credentials`
  (`"twilio" => %{account_sid, auth_token, messaging_service_sid, sms_from}`), lidas de
  `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_MESSAGING_SERVICE_SID` e
  `TWILIO_SMS_FROM`. Em dev podem faltar (o envio falha com `:missing_credentials`).
- **Próximo passo para WhatsApp:** estender `OutboundMessage` com template
  (`content_sid` + variáveis) e declarar `:whatsapp` neste provider, com endereço
  `whatsapp:+E164`; o erro `63016` deve virar `:permanent` / `:outside_session_window`.
- **Antes de produção:** validar contra uma conta Twilio real (modo de teste/credenciais de
  teste) os pontos não confirmados: comportamento de 5xx e ausência de idempotência.
