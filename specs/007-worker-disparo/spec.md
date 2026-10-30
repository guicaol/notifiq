# Spec 007 — Worker de disparo, retentativas e backoff

**Fase relacionada:** Fase de disparo — execução assíncrona
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 006 (`Mensageria`), Spec 004 (`Channels.Dispatcher`)

## Goal

Executar o envio de cada mensagem reservada fora do caminho da requisição, tentando de novo
quando for seguro, desistindo no momento certo, e garantindo que **nenhuma reserva fique
presa para sempre** — nem por falha do provedor, nem por crash do worker, nem por perda do
job.

## User story

Como plataforma, preciso que cada mensagem reservada seja enviada por um worker que
reaja de forma diferente a cada tipo de falha (esperar e repetir, desistir e devolver o
crédito, ou parar sem reenviar quando há risco de duplicar), para que o lojista não perca
crédito nem notificação, e o cliente final não receba a mesma mensagem duas vezes.

## Decisões de projeto

| Decisão | Escolha | Motivo |
|---|---|---|
| Reserva + enfileiramento | **Mesma transação** (`request_dispatch/1`) | Fecha a lacuna "reservou e caiu antes de enfileirar", que deixaria crédito preso |
| Dados no job | Só `tenant_id` e `message_log_id` | O Oban grava os args em `oban_jobs`; telefone e corpo ficam só em `message_logs` |
| Resultado `uncertain` | **Não reenvia** por padrão; vira `unconfirmed` (crédito mantido, revisão manual) | O Twilio não tem idempotência documentada (Spec 005): reenviar pode duplicar o SMS. Configurável |
| Esgotar tentativas de `retryable` | `give_up` → `failed` + **reembolso** | A mensagem nunca saiu |
| Rede de segurança | Sweeper periódico | Cobre job descartado/perdido que deixou o log preso |

## Requisitos funcionais (EARS)

- **FR-1:** `Mensageria.request_dispatch/1` DEVE reservar o disparo (Spec 006, FR-1) **e**
  inserir o job `DispatchWorker` na mesma transação. Se qualquer parte falhar, nada fica
  gravado: nem log, nem débito, nem job.
- **FR-2:** QUANDO o evento já tiver reserva (`{:duplicate, log}`), `request_dispatch/1` NÃO
  DEVE enfileirar outro job; o job do primeiro pedido continua sendo o único.
- **FR-3:** DEVE existir no máximo **um job ativo por `message_log_id`**
  (`unique` por `message_log_id`, estados incompletos), de modo que duas tentativas do mesmo
  log não corram em paralelo.
- **FR-4:** Os `args` do job DEVEM conter apenas `tenant_id` e `message_log_id`; NUNCA
  telefone, corpo ou credenciais.
- **FR-5:** `DispatchWorker.perform/1` DEVE chamar `Mensageria.attempt_dispatch/2` e reagir
  conforme o estado do log resultante (tabela abaixo).
- **FR-6:** O atraso entre tentativas DEVE crescer exponencialmente (`base * 2^(tentativa-1)`),
  limitado por um teto, com jitter proporcional, todos configuráveis; a função de atraso DEVE
  ser pura e testável.
- **FR-7:** QUANDO a última tentativa permitida terminar sem sucesso definitivo, o worker
  DEVE fechar o log com `Mensageria.give_up/2` (que reembolsa um `pending` e preserva o
  crédito de um `uncertain`) e encerrar o job sem novas tentativas.
- **FR-8:** SE `perform/1` levantar exceção, e for a última tentativa, o worker DEVE tentar
  fechar o log com `give_up/2` (best-effort, sem mascarar o erro original) e relançar a
  exceção; nas demais tentativas apenas relançar, para o Oban tentar de novo.
- **FR-9:** O worker NUNCA DEVE reenviar um log em estado final: log `sent`, `failed` ou
  `unconfirmed` encerra o job com sucesso sem chamar o provider.
- **FR-10:** O número de reenvios após `uncertain` DEVE ser configurável
  (`:dispatch_uncertain_resends`, padrão 0); com 0, o primeiro `uncertain` encerra o log como
  `unconfirmed`.
- **FR-11:** O `Sweeper` DEVE rodar periodicamente e fechar com `give_up/2` todo log
  `pending` ou `uncertain` parado há mais de `:dispatch_stale_after` segundos **e sem job
  ativo** — iterando por tenant, sempre com consultas filtradas por `tenant_id`
  (Constitution, princípio 7).
- **FR-12:** Cada job DEVE ter timeout (`timeout/1`), para que uma chamada travada não ocupe
  a fila indefinidamente.
- **FR-13:** O envio DEVE rodar em fila própria (`:dispatch`), separada da ingestão, para que
  uma lentidão do provedor não atrase o recebimento de webhooks (Constitution, princípio 8).

## Reação do worker (FR-5, FR-7, FR-10)

| Estado do log após a tentativa | Não é a última tentativa | É a última tentativa |
|---|---|---|
| `sent` | `:ok` | `:ok` |
| `failed` (falha permanente, já reembolsada) | `:ok`, sem retry | `:ok` |
| `pending` (falha `retryable`) | `{:error, _}` → retry com backoff | `give_up` → `failed` + reembolso; `{:cancel, :retries_exhausted}` |
| `uncertain`, reenvios restantes | `{:error, _}` → retry com backoff | `give_up` → `unconfirmed`; `{:cancel, _}` |
| `uncertain`, sem reenvios restantes (padrão) | `give_up` → `unconfirmed`; `{:cancel, :uncertain_not_resent}` | idem |
| log já final (`{:error, :already_final}`) | `:ok` | `:ok` |
| log inexistente para o tenant (`:not_found`) | `{:cancel, :message_log_not_found}` | idem |

## Non-goals

- **Ligar o `EventWorker` (Spec 002) ao `request_dispatch/1`.** Falta decidir *o que enviar*
  (template do evento, canal, provider) e *para qual tenant* (Spec 008 e a spec de
  templates). O `request_dispatch/1` é o ponto de entrada pronto para isso.
- Limite de taxa ou justiça entre tenants dentro da fila (um tenant ruidoso pode ocupar a
  fila `:dispatch`); revisitar com dados reais.
- Revisão manual de logs `unconfirmed` e alertas.
- Reenvio automático inteligente de `uncertain` (depende de um provider com idempotência
  confirmada).

## Pontos em aberto

1. **Valores de backoff e de tentativas** (30 s de base, teto de 1 h, 6 tentativas) são
   chutes razoáveis, não medidos. Ajustar com a taxa real de `rate_limited` do provedor.
2. **Job zumbi:** se o Lifeline resgatar um job que ainda está rodando num nó travado, duas
   execuções podem coincidir. É raro; o `give_up`/`record_outcome` condicionais impedem
   dupla cobrança e duplo reembolso, mas não um duplo envio nesse caso extremo.
3. **`uncertain` sem reenvio exige revisão manual**; a política final depende da taxa
   observada de incertezas.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Saldo insuficiente em `request_dispatch/1` | `{:error, :insufficient_credits}`; nenhum job |
| Dois `request_dispatch/1` simultâneos do mesmo evento | Um log, um débito e **um job** |
| Job executado de novo depois de ter enviado | `:ok` sem chamar o provider (log já `sent`) |
| Provider devolve falha permanente na 1ª tentativa | Log `failed`, reembolso, job encerrado sem retry |
| Exceção no worker na última tentativa | Log fechado por `give_up`, exceção relançada |
| Job descartado pelo Oban com o log ainda `pending` | O Sweeper o fecha e reembolsa depois de `:dispatch_stale_after` |
| Log antigo mas com retry agendado para daqui a 1 h | Preservado: tem job ativo |
| Dois tenants com logs presos | Cada um é varrido e fechado de forma independente |

## Critérios de aceite

- **AC-1:** `request_dispatch/1` cria log, débito, lançamento e **um** job
  `DispatchWorker` com `tenant_id` e `message_log_id`.
- **AC-2:** Saldo insuficiente, evento/tenant inexistente ou pedido inválido: nenhum job,
  nenhum log, nenhum débito.
- **AC-3:** `request_dispatch/1` repetido para o mesmo evento: `{:duplicate, log}` e
  continua havendo um único job.
- **AC-4:** **Concorrência real:** 10 `request_dispatch/1` paralelos do mesmo evento geram 1
  log, 1 débito e 1 job.
- **AC-5:** Os `args` do job não contêm o telefone nem o corpo da mensagem.
- **AC-6:** Cada linha da tabela de reação do worker tem um teste, incluindo o reembolso na
  última tentativa e a ausência de reembolso em `uncertain`.
- **AC-7:** Um log já `sent` não é enviado de novo quando o job roda outra vez (o provider
  não é chamado e o log não muda).
- **AC-8:** `Backoff.delay/2` cresce exponencialmente, respeita o teto, e com jitter fica
  dentro de `±jitter` do valor base (testado em muitas amostras); a primeira tentativa usa a
  base.
- **AC-9:** Com `:dispatch_uncertain_resends` = N, o `uncertain` é reenviado N vezes e na
  seguinte vira `unconfirmed`.
- **AC-10:** Exceção no worker: nas tentativas intermediárias o log fica intacto; na última, é
  fechado por `give_up` e a exceção é relançada.
- **AC-11:** O Sweeper fecha logs presos sem job ativo (com reembolso de `pending`), ignora
  logs recentes, logs com job ativo e logs finais, e trata cada tenant separadamente.
- **AC-12:** O worker é `unique` por `message_log_id`: inserir dois jobs para o mesmo log
  resulta em um.
- **AC-13:** A configuração do Oban declara as filas `:dispatch` e `:maintenance` e os
  plugins Lifeline, Pruner e Cron (Sweeper), e desliga plugins e filas em teste.
- **AC-14:** O teste de arquitetura continua passando (o worker não cita Bling nem Twilio).

## Rastreabilidade

- Backlog: tarefas de disparo relativas a "worker Oban de envio", "retentativas e backoff".
- Constitution: princípios 5 e 8; qualidade: cobertura obrigatória em **resiliência de
  worker**.
- Spec 006 (estados e reembolso), Spec 004 (classes de erro), Spec 005 (por que `uncertain`
  não é reenviado por padrão).

## Notas de implementação

- **Onde está:** `Mensageria.request_dispatch/1` (reserva + job na mesma transação),
  `DispatchWorker` (fila `:dispatch`, 6 tentativas, `unique` por `message_log_id`),
  `Backoff` (função pura), `DispatchSettings` (configuração `:dispatch`), `Sweeper` (fila
  `:maintenance`, Cron a cada 15 min) e `Mensageria.list_stale_logs/3`.
- **Retorno do worker:** usa `{:cancel, motivo}` para encerrar sem novas tentativas;
  `{:discard, _}` está deprecado no Oban 2.24.
- **Teste da exceção no worker:** o dispatcher já contém exceções do provider, então o teste
  troca o módulo de tentativa por `Notifiq.Test.CrashingAttempt`
  (`config :notifiq, :dispatch_attempt_module`), um ponto de injeção só usado em teste.
- **Concorrência real** (`ConcurrencyTest`, conexões fora do sandbox): 10
  `request_dispatch` paralelos do mesmo evento geram 1 log, 1 débito e 1 job; com crédito
  para 3 de 10 pedidos, existem exatamente 3 jobs, um por log pago.
- **Verificação por mutação:** trocar `>=` por `>` na detecção da última tentativa faz
  falharem 3 testes; fazer o `list_stale_logs` ignorar jobs ativos faz falharem 2.
- **Teste ao vivo em dev** (sem credenciais do Twilio, portanto sem nenhuma chamada HTTP):
  reserva → job executado pela fila real → `failed` (`missing_credentials`) → reembolso;
  livro-razão `[purchase 3, dispatch -1, refund 1]`, job `completed`.
- **Ligado na Spec 009:** o `EventWorker` agora aplica o template do tenant ao evento e chama
  `request_dispatch/1`.
