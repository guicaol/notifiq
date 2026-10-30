# Spec 006 — Núcleo Mensageria: crédito transacional e idempotência de disparo

**Fase relacionada:** Fase de disparo — núcleo de domínio
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 002 (`webhook_events`), Spec 004 (`Channels.Dispatcher`)

## Goal

Garantir, no núcleo `Notifiq.Mensageria`, que **cada evento recebido gera no máximo um
disparo e consome exatamente um conjunto de créditos**, mesmo com entregas repetidas,
requisições concorrentes e falhas no meio do caminho — e que o crédito só fique gasto
quando a mensagem foi (ou pode ter sido) enviada.

## User story

Como plataforma que cobra por mensagem, preciso que o débito de crédito e o registro do
disparo aconteçam juntos e sem condição de corrida, e que uma falha definitiva de envio
devolva o crédito, para que nenhum tenant seja cobrado duas vezes pelo mesmo evento, fique
com saldo negativo ou perca crédito por uma mensagem que nunca saiu.

## Modelo

### Tabelas

| Tabela | Papel | Chaves relevantes |
|---|---|---|
| `tenants` | Dono do saldo (mínimo: `id`, `name`, `credit_balance`). A spec de multi-tenancy (008) a estende. | `CHECK (credit_balance >= 0)` |
| `message_logs` | Um registro por disparo | `UNIQUE (webhook_event_id)`; FK para `webhook_events` e `tenants` |
| `credit_transactions` | Livro-razão: toda mudança de saldo | `UNIQUE (message_log_id, reason)` quando há log |

### Estados de `message_logs.status`

```
            ┌─ sent ───────────────────────── (final)
pending ────┼─ failed ── (reembolsa) ──────── (final)
   ▲        └─ uncertain ─┬─ sent / failed
   │ retryable            └─ unconfirmed ─── (final, sem reembolso)
   └──────┘
```

| Resultado do envio (`Channels.Dispatcher`) | Novo estado | Crédito |
|---|---|---|
| `{:ok, receipt}` | `sent` | mantido (gasto) |
| `{:error, {:retryable, _}}` | `pending` (tentativa registrada) | mantido reservado |
| `{:error, {:uncertain, _}}` | `uncertain` | mantido: pode ter sido enviada |
| `{:error, {:permanent, _}}` | `failed` | **reembolsado** |

`give_up/2` encerra o que o worker desistiu de tentar: `pending` → `failed` (reembolsa);
`uncertain` → `unconfirmed` (sem reembolso, para revisão manual). `sent`, `failed` e
`unconfirmed` são finais e imutáveis.

## Requisitos funcionais (EARS)

- **FR-1:** `Mensageria.reserve/1` DEVE, numa única transação (`Ecto.Multi`), inserir o
  `message_log` (`pending`), debitar o custo do saldo do tenant e gravar a entrada
  correspondente no livro-razão. Ou tudo acontece, ou nada.
- **FR-2:** O débito DEVE ser um `UPDATE ... WHERE credit_balance >= custo` atômico, que
  trava a linha do tenant até o commit; o saldo NUNCA DEVE ficar negativo (reforçado por
  `CHECK` no banco).
- **FR-3:** SE o saldo for insuficiente, `reserve/1` DEVE retornar
  `{:error, :insufficient_credits}` sem criar `message_log` nem entrada no livro-razão.
- **FR-4:** SE já existir `message_log` para o `webhook_event_id`, `reserve/1` DEVE retornar
  `{:duplicate, log}` sem debitar nada e sem criar registros (idempotência garantida pelo
  `UNIQUE` no banco, não por checagem em memória).
- **FR-5:** Todo `message_log` DEVE referenciar um `webhook_event` existente e um tenant
  existente; caso contrário `reserve/1` retorna `{:error, :unknown_event}` ou
  `{:error, :unknown_tenant}`.
- **FR-6:** Todo pedido de reserva DEVE ser validado antes de tocar o banco (canal conhecido,
  telefone E.164, corpo válido, provider não vazio, custo inteiro ≥ 1); inválido →
  `{:error, :invalid_request}`.
- **FR-7:** `record_outcome/2` DEVE aplicar a tabela de transições acima numa transação,
  somente a partir de `pending` ou `uncertain`; chamada sobre um log final retorna
  `{:error, :already_final}` e não altera nada.
- **FR-8:** O reembolso (falha `permanent` ou `give_up` de `pending`) DEVE devolver o custo
  ao saldo e gravar a entrada no livro-razão na mesma transação da mudança de estado, e DEVE
  ocorrer no máximo uma vez por `message_log`.
- **FR-9:** O saldo de cada tenant DEVE ser igual à soma das suas entradas no livro-razão
  (invariante verificável).
- **FR-10:** `attempt_dispatch/2` DEVE recarregar o log (filtrando por tenant), recusar logs
  finais sem chamar nenhum provider, chamar `Channels.Dispatcher.dispatch/2` com
  `idempotency_key` igual ao `id` do log, e registrar o resultado via `record_outcome/2`.
- **FR-11:** `add_credits/3` DEVE somar créditos e gravar a entrada no livro-razão
  atomicamente; quantidade inválida (não inteira ou ≤ 0) → `{:error, :invalid_amount}`.
- **FR-12:** **Isolamento de tenant (Constitution, princípio 7):** toda função de leitura ou
  escrita DEVE receber o `tenant_id` e filtrá-lo na própria query; um tenant nunca lê nem
  altera `message_logs` ou lançamentos de outro.
- **FR-13:** O núcleo NÃO DEVE conhecer nenhuma fonte nem provedor específico (princípios 1
  e 2): o provider é só a chave textual passada pelo chamador.

## Non-goals

- Worker Oban, retentativas, backoff e limite de tentativas (Spec 007). O `attempt_dispatch`
  é o corpo que o worker chamará; **evitar duas tentativas simultâneas do mesmo log é do
  worker** (unicidade de job por `message_log_id`), pois não se segura lock de banco durante
  uma chamada HTTP.
- Escolha de provider/canal/template por evento e renderização do corpo (spec de templates).
- Plug/middleware de isolamento, usuários, `tenant_id` em `webhook_events` e validação de
  que o evento pertence ao tenant (Spec 008). Aqui o `tenant_id` é informado pelo chamador.
- Compra de crédito, cobrança e preços; custo variável por segmento de SMS (aqui o custo é
  um inteiro informado, padrão 1).
- Política de retenção do corpo e do telefone guardados em `message_logs` (LGPD): ver
  "Pontos em aberto".

## Pontos em aberto

1. **Retenção de dados pessoais:** `message_logs` guarda `recipient` e `body` porque o
   reenvio precisa deles. É preciso definir por quanto tempo e se o corpo é apagado após o
   estado final.
2. **Reembolso por falha do provider conta como saldo do tenant imediatamente:** não há
   período de graça nem aprovação; revisitar se houver fraude por falhas induzidas.
3. **`uncertain` nunca reembolsa sozinho:** `unconfirmed` exige revisão manual (fora de
   escopo); a política final pode vir de dados reais de taxa de incerteza.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Duas reservas simultâneas do mesmo evento | Uma vence; a outra recebe `{:duplicate, log}`; saldo debitado uma vez |
| N reservas simultâneas, saldo para K < N | Exatamente K têm sucesso; N−K recebem `:insufficient_credits`; saldo final 0 |
| Falha após inserir o log e antes do débito | Transação inteira revertida; nem log nem débito |
| `record_outcome` repetido para a mesma falha permanente | Reembolsa uma vez; a segunda chamada devolve `:already_final` |
| `uncertain` seguido de sucesso numa nova tentativa | Vira `sent`; crédito já estava gasto; nenhum reembolso |
| `uncertain` seguido de falha permanente | Vira `failed` e reembolsa |
| Evento duplicado cujo log pertence a outro tenant | `{:error, :conflict}`; não revela o log |
| Tenant tenta ler o log de outro | `nil` / lista vazia, como se não existisse |

## Critérios de aceite

- **AC-1:** `reserve/1` com saldo suficiente cria o log `pending`, debita o custo e grava um
  lançamento negativo `dispatch` ligado ao log.
- **AC-2:** Com saldo insuficiente: `{:error, :insufficient_credits}`, saldo intacto, zero
  logs, zero lançamentos.
- **AC-3:** Segunda reserva do mesmo evento: `{:duplicate, log}`, saldo debitado uma única
  vez, um único log.
- **AC-4:** **Concorrência real** (conexões fora do sandbox): 10 reservas paralelas do mesmo
  evento resultam em exatamente 1 `{:ok, _}` e 9 `{:duplicate, _}`, um log e um débito.
- **AC-5:** **Concorrência real:** com saldo 3, 10 reservas paralelas de eventos distintos
  resultam em exatamente 3 `{:ok, _}` e 7 `:insufficient_credits`; saldo final 0 e nunca
  negativo.
- **AC-6:** Evento ou tenant inexistente: `:unknown_event` / `:unknown_tenant`, sem efeitos.
- **AC-7:** Pedido inválido (canal, telefone, corpo, provider vazio, custo ≤ 0): 
  `:invalid_request`, sem tocar o banco.
- **AC-8:** Cada linha da tabela de transições é coberta por um teste, incluindo o reembolso
  da falha permanente e a ausência de reembolso em `uncertain`.
- **AC-9:** `record_outcome/2` sobre log final devolve `:already_final` e não muda saldo nem
  livro-razão; um reembolso nunca ocorre duas vezes (nem em chamadas paralelas).
- **AC-10:** `give_up/2`: `pending` → `failed` com reembolso; `uncertain` → `unconfirmed` sem
  reembolso; log final → `:already_final`.
- **AC-11:** `attempt_dispatch/2` com provider fake envia com `idempotency_key == log.id`,
  grava `provider_message_id` e deixa o log `sent`; num log final não chama o provider.
- **AC-12:** Invariante: após qualquer sequência de operações, `credit_balance` do tenant é
  igual à soma do seu livro-razão (teste de propriedade sobre sequências aleatórias).
- **AC-13:** **Isolamento:** o tenant A não lê, lista, atualiza nem reembolsa registros do
  tenant B; operações de A não alteram o saldo de B.
- **AC-14:** `add_credits/3` soma e lança atomicamente; valor inválido → `:invalid_amount`.
- **AC-15:** O teste de arquitetura (Spec 004) continua passando: o núcleo não cita Bling nem
  Twilio.

## Rastreabilidade

- Backlog: tarefas de núcleo `Mensageria` relativas a "consumo de crédito" e "idempotência"
  (IDs `MSG-XXX` a vincular).
- Constitution: princípios 4, 5 e 7; qualidade: cobertura obrigatória em idempotência,
  isolamento de tenant e transação de crédito.
- Spec 002 (idempotência de entrada) e Spec 004 (envio), que esta spec une.

## Notas de implementação

- **Onde está:** `Notifiq.Mensageria` (API pública), `Mensageria.Credits` (débito, crédito e
  lançamento, sempre dentro do `Ecto.Multi` do chamador), `MessageLog`, `CreditTransaction`
  e o mínimo de `Notifiq.Tenants` (a Spec 008 o estende). Migrations: `tenants` e
  `message_logs` + `credit_transactions`.
- **Ordem na reserva:** evento existe → tenant existe → insere o log (detecta duplicata
  antes de tocar o saldo, para que reentregas não disputem o lock do tenant) → débito
  condicional → lançamento. Qualquer falha desfaz tudo.
- **Duplicata concorrente:** `INSERT ... ON CONFLICT DO NOTHING`; a segunda transação
  espera o índice único e então recebe zero linhas. Se a primeira for desfeita (ex.: saldo
  insuficiente), a segunda assume a reserva.
- **`give_up/2` e `record_outcome/2`** usam `UPDATE ... WHERE status IN (...)`: de duas
  chamadas simultâneas só uma casa. O reembolso é protegido em duas camadas (a transição
  condicional e o `UNIQUE (message_log_id, reason)` do livro-razão).
- **Testes de concorrência reais:** o sandbox do Ecto serializa tudo numa conexão e
  esconderia as corridas; por isso `ConcurrencyTest` usa `Sandbox.unboxed_run/2` (conexões
  reais, dados commitados e removidos no `on_exit`; módulo síncrono). **Todo dado commitado
  ali precisa do prefixo `concurrency-test`**, ou a limpeza não o encontra e ele vaza para
  os outros testes (aconteceu durante o desenvolvimento).
- **Verificação por mutação:** remover a condição `credit_balance >= custo` do débito faz
  falharem 5 testes, incluindo os de concorrência real.
- **Pendente para a Spec 007:** unicidade de job por `message_log_id` (evita duas tentativas
  simultâneas do mesmo log) e a política de reenvio de logs `uncertain`.
- **Resolvido na Spec 008:** `webhook_events` tem `tenant_id` e a reserva recusa um evento
  que não seja do tenant (`:unknown_event`). O livro-razão ganhou a coluna `seq` para uma
  ordem que nunca empata.
