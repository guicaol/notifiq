# Spec 002 — Camada de abstração de integrações

**Fase relacionada:** Fase 4 — Abstração de integrações + ingestão
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 001 (scaffolding), tabela `webhook_events` (criada nesta spec, ver notas)

## Goal

Prover um endpoint genérico e um mecanismo de roteamento (`registry`) que permitam a qualquer
fonte (CRM/ERP) conectar-se ao núcleo de mensageria através de um contrato comum, sem que o
núcleo precise conhecer detalhes de nenhuma fonte específica.

## User story

Como plataforma, preciso receber webhooks de múltiplas fontes diferentes e traduzi-los para um
formato único antes de processá-los, para que adicionar uma nova fonte no futuro não exija
alterar o núcleo de processamento — apenas escrever e registrar um novo adapter.

## Requisitos funcionais (EARS)

- **FR-1:** O sistema DEVE expor um endpoint `POST /api/webhooks/:source_key` que aceita um
  corpo JSON arbitrário.
- **FR-2:** QUANDO `:source_key` não corresponder a nenhum adapter registrado no registry, o
  sistema DEVE responder HTTP 404 e não deve processar o corpo da requisição.
- **FR-3:** QUANDO `:source_key` corresponder a um adapter registrado, o sistema DEVE invocar
  `verify_authenticity/2` do adapter correspondente antes de interpretar o corpo da requisição.
- **FR-4:** SE `verify_authenticity/2` retornar `{:error, reason}`, o sistema DEVE responder
  HTTP 401 e não deve criar nenhum registro em `webhook_events` nem enfileirar job.
- **FR-5:** SE `verify_authenticity/2` retornar `:ok`, o sistema DEVE invocar `parse/1` do
  adapter para obter um evento canônico.
- **FR-6:** QUANDO `parse/1` retornar `{:ok, :ignore}`, o sistema DEVE responder HTTP 200 sem
  criar registro em `webhook_events` nem enfileirar job.
- **FR-7:** QUANDO `parse/1` retornar `{:ok, %CanonicalEvent{}}`, o sistema DEVE verificar a
  unicidade de `(source, external_event_id)` em `webhook_events` antes de enfileirar qualquer
  job.
- **FR-8:** SE a tupla `(source, external_event_id)` já existir em `webhook_events`, o sistema
  DEVE responder HTTP 200 e não deve enfileirar um segundo job.
- **FR-9:** O sistema DEVE responder HTTP 200 ao webhook em até 200ms (percentil 95), delegando
  qualquer processamento além da validação e enfileiramento a um job Oban assíncrono.
- **FR-10:** Todo módulo adapter DEVE implementar o behaviour `Notifiq.Integrations.Source`,
  com os callbacks `source_key/0`, `verify_authenticity/2`, `extract_event_id/1`, `parse/1`.
- **FR-11:** O mapeamento de `source_key` para módulo adapter DEVE vir de configuração de
  aplicação (`config.exs` / `runtime.exs`), nunca de um `case`/`cond` hardcoded no controller.
- **FR-12:** SE `parse/1` lançar uma exceção não tratada, o sistema DEVE capturá-la, registrar
  um log estruturado com `source_key` e o erro, e responder HTTP 500 — sem derrubar o processo
  do endpoint nem afetar outras requisições em andamento.

## Non-goals

- Implementação de um adapter concreto (Bling é a Spec 003, separada).
- Lógica de negócio de crédito ou disparo de mensagem (núcleo `Mensageria`, spec futura).
- Contrato de canal de saída (`Channels.Provider` — spec futura, mesmo padrão espelhado).

## Contrato (referência normativa)

O behaviour completo está em [`contracts/source_behaviour.ex`](contracts/source_behaviour.ex).
O schema do evento canônico está em
[`contracts/canonical_event.schema.json`](contracts/canonical_event.schema.json).
Qualquer divergência entre este documento e os arquivos de contrato deve ser resolvida a favor
dos arquivos de contrato — eles são a fonte executável.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Payload não é JSON válido | HTTP 400, log estruturado, nenhum registro criado |
| Dois webhooks idênticos em paralelo (mesma fonte, mesmo `external_event_id`) | Apenas um job enfileirado — garantido por constraint `UNIQUE(source, external_event_id)` no banco, não apenas checagem em memória |
| Adapter registrado mas módulo não implementa todos os callbacks | Falha detectável em tempo de compilação ou boot (via `@behaviour` + `Code.ensure_loaded?/1`), não em runtime na primeira requisição |
| `source_key` com maiúsculas/minúsculas diferentes (`Bling` vs `bling`) | Tratado como fontes diferentes — normalização de case é responsabilidade de quem configura o registry, não do endpoint |
| Adapter demora além do timeout configurado em `verify_authenticity/2` | Requisição retorna 401 ou 500 conforme o tipo de falha; nunca trava o endpoint indefinidamente |

## Critérios de aceite

- **AC-1:** Um adapter fake registrado em ambiente de teste é roteado corretamente por
  `POST /api/webhooks/fake`.
- **AC-2:** `POST /api/webhooks/inexistente` retorna HTTP 404.
- **AC-3:** Adapter fake cujo `verify_authenticity/2` retorna `{:error, :invalid_signature}`
  resulta em HTTP 401 e zero registros em `webhook_events`.
- **AC-4:** Enviar o mesmo payload duas vezes (mesmo `source_key` e `external_event_id`)
  resulta em exatamente um job Oban enfileirado — testado com duas requisições disparadas em
  paralelo (`Task.async`), não sequenciais.
- **AC-5:** Adapter fake cujo `parse/1` retorna `{:ok, :ignore}` resulta em HTTP 200 e nenhum
  job enfileirado.
- **AC-6:** Existe uma suíte de "contrato de adapter" (`AdapterContractTest`, via
  `ExUnit.Case` compartilhado com `use`) que roda contra qualquer módulo passado a ela e
  verifica que os 4 callbacks estão implementados e retornam os tipos declarados no behaviour.
  Todo novo adapter (incluindo o do Bling, Spec 003) DEVE rodar essa suíte.
- **AC-7:** Simular uma exceção dentro de `parse/1` de um adapter fake resulta em HTTP 500,
  um log estruturado contendo `source_key`, e uma segunda requisição imediatamente depois
  (a outro adapter) é processada normalmente — comprovando isolamento.
- **AC-8:** Um teste de carga simples (ex.: 50 requisições concorrentes ao endpoint) confirma
  que o percentil 95 de tempo de resposta fica abaixo de 200ms com o processamento pesado
  mockado para ser lento (simulando um `parse/1` ou I/O demorado sendo corretamente
  delegado ao job assíncrono, não bloqueando a resposta).

## Rastreabilidade

- Backlog: tarefas da Fase 4 relativas a "Rota e controller do webhook", "Verificação de
  idempotência", "Implementação da fila Oban".
- Constitution: princípios 1, 3, 4, 8.
- Documentação técnica: Seção 4 (Arquitetura), ADR-04.

## Notas de implementação (divergências e decisões)

- **`webhook_events`** não existia (a spec a assumia da Fase 2); foi criada aqui, sem coluna
  `tenant_id`. A coluna e o teste de isolamento chegam com a spec de multi-tenancy (008).
- **Corpo bruto:** `NotifiqWeb.CacheBodyReader` guarda o corpo exato em
  `conn.assigns.raw_body` apenas para `/api/webhooks/*`, para adapters que validam HMAC.
- **`{:error, reason}` de `parse/1`** responde HTTP **200** `{"status":"rejected","reason":...}`
  com log `warning` e nada é gravado (a spec não definia o status). Um evento assinado mas
  inutilizável nunca vai se tornar utilizável; um 4xx faria fontes como o Bling retentar por
  dias e depois desativar o webhook. Timeout/exceção/retorno inválido de callback → 500.
- **Timeout de callbacks:** `:integration_callback_timeout` (padrão 5000 ms), aplicado a
  `verify_authenticity/2` e `parse/1`.
- **Credenciais:** enquanto a tabela `integrations` não existe, vêm de
  `config :notifiq, :integration_credentials` (mapa `source_key => credentials`, vazio por
  padrão). Quando um adapter real precisar de segredo, preencher em `runtime.exs` a partir de
  variáveis de ambiente — nunca no código-fonte.
- **Worker:** `Notifiq.Mensageria.EventWorker` apenas carrega o evento; crédito e disparo
  são das specs 006/007.
- **Lacuna conhecida:** o 400 por JSON inválido não gera log estruturado (o erro é levantado
  pelo `Plug.Parsers`, antes do controller).
- **AC-4/AC-8:** no sandbox do Ecto as requisições paralelas compartilham uma conexão e são
  serializadas; a garantia contra corrida real vem do índice único, testado também
  diretamente no banco.
