# Spec 008 — Multi-tenancy: resolução do tenant e isolamento

**Fase relacionada:** Fundação multi-tenant
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 002 (ingestão), Spec 003 (Bling), Spec 006 (`tenants`, `message_logs`)

## Goal

Fazer com que **todo webhook recebido pertença a um tenant determinado pelo sistema — nunca
informado pelo chamador** — e que nenhuma tabela operacional guarde ou aceite dado sem
tenant, fechando as duas lacunas que as specs anteriores deixaram anotadas: `webhook_events`
sem `tenant_id` (Spec 002) e a reserva de crédito confiando no `tenant_id` do chamador
(Spec 006).

## User story

Como plataforma que atende vários lojistas, preciso saber de qual lojista é cada webhook
que chega e garantir que ele só afete o saldo, os registros e as filas desse lojista, para
que um erro ou um ataque nunca misture dados nem créditos de dois clientes.

## Como o tenant é determinado

O webhook não carrega o tenant. A fonte identifica **a conta dela** (no Bling, o
`companyId` do envelope), e o tenant é quem a conectou:

```
webhook ──► adapter registrado? ──► assinatura válida? ──► conta da fonte ──► integração ativa ──► tenant
            (404)                    (401)                  (adapter extrai)    (tabela integrations)
```

Pontos de projeto:

| Decisão | Escolha | Motivo |
|---|---|---|
| Quando ler o `companyId` | **Depois** de verificar a assinatura | O corpo só é interpretado depois de autenticado (Spec 002, FR-3); assim também não há enumeração de contas: assinatura inválida é 401 qualquer que seja a conta |
| Credenciais de verificação | Continuam por fonte (config), não por integração | O Bling assina com o *client secret* do app da plataforma, único. Credenciais por tenant (tokens OAuth) exigem criptografia (Constitution, princípio 6) e ficam para a spec do OAuth |
| Conta desconhecida ou integração desativada, com assinatura válida | **200** `{"status":"unknown_account"}`, nada gravado | Retornar 4xx faria o Bling retentar por dias e desativar o webhook para **todas** as lojas (Spec 003) |
| Unicidade de eventos | Continua `(source, external_event_id)` global | Princípio 4; ids de evento da fonte são globalmente únicos |
| Plug/middleware de isolamento | **Não nesta spec** | Não existe usuário nem sessão: um plug sem autenticação teria de confiar num header, o que seria inseguro. A fronteira hoje é o formato das funções (todas exigem `tenant_id`) mais os testes. O plug vem com a spec de autenticação |

## Mudança de contrato

`Notifiq.Integrations.Source` ganha um **quinto callback**:

```elixir
@callback extract_account_id(raw_payload()) :: {:ok, String.t()} | :error
```

Identifica a conta da fonte que originou o evento (Bling: `companyId`). É chamado só depois
de a assinatura ser verificada, deve ser puro e nunca lançar exceção. O schema do evento
canônico **não muda** (continua versão 1): o `tenant_id` já existia nele e passa a ser
preenchido pelo núcleo, "a partir da integração autenticada, não pelo adapter".

## Requisitos funcionais (EARS)

- **FR-1:** DEVE existir a tabela `integrations` (`tenant_id`, `source`,
  `external_account_id`, `status` `active|disabled`), e no máximo **uma integração ativa**
  por `(source, external_account_id)`, garantido por índice único parcial no banco.
- **FR-2:** `Tenants.connect_integration/2` DEVE criar a integração ativa do tenant, validar
  que `source` está registrada, e recusar uma conta já conectada ativamente (por qualquer
  tenant). O `tenant_id` NUNCA vem dos parâmetros externos.
- **FR-3:** `Tenants.disconnect_integration/2` DEVE desativar a integração **do próprio
  tenant** (filtrando por `tenant_id`); depois disso a conta pode ser conectada por outro
  tenant.
- **FR-4:** `webhook_events` DEVE ter `tenant_id NOT NULL` com chave estrangeira.
- **FR-5:** Depois de verificada a assinatura, a ingestão DEVE extrair a conta
  (`extract_account_id/1`), resolver a integração ativa e gravar o evento com o `tenant_id`
  dela, também no `tenant_id` do evento canônico.
- **FR-6:** SE a conta não tiver integração ativa, a ingestão DEVE responder HTTP 200
  `{"status":"unknown_account"}`, não gravar evento, não enfileirar job e registrar um log
  `info` com `source_key` (sem dados da conta além do necessário).
- **FR-7:** SE `extract_account_id/1` devolver `:error` ou falhar, a ingestão DEVE tratá-lo
  como payload inutilizável: HTTP 200 `rejected`, `missing_account_id` (Spec 002).
- **FR-8:** SE a assinatura for inválida, a resposta DEVE ser a mesma 401 quer a conta exista
  ou não.
- **FR-9:** `Mensageria.reserve/1` e `request_dispatch/1` DEVEM recusar um `webhook_event` que
  não pertença ao `tenant_id` informado (`{:error, :unknown_event}`), sem efeitos e sem
  revelar que o evento existe.
- **FR-10:** O job de ingestão (`EventWorker`) DEVE carregar o evento filtrando por
  `tenant_id`; evento de outro tenant ou inexistente cancela o job.
- **FR-11:** Toda leitura e escrita nas tabelas novas ou alteradas DEVE receber `tenant_id` e
  filtrá-lo na query. A única consulta sem tenant é `Tenants.resolve_tenant/2`, porque é ela
  que **determina** o tenant, e só é alcançável depois da assinatura verificada.
- **FR-12:** Todo adapter DEVE implementar `extract_account_id/1`; a suíte de contrato (Spec
  002, AC-6) DEVE verificá-lo.
- **FR-13:** A migration DEVE ser reversível e DEVE falhar (sem apagar nada) se já houver
  eventos sem tenant.

## Non-goals

- Usuários, login, sessão e o plug de isolamento das telas (spec de autenticação).
- Credenciais por integração e sua criptografia: tokens OAuth do Bling (spec do OAuth).
- Tela ou API para o tenant conectar contas (hoje `connect_integration/2` é a função de
  domínio que essas telas chamarão).
- Convite de usuários, papéis e limites por plano.
- Escolher texto, canal e provider por evento (resolvido na Spec 009).

## Pontos em aberto

1. **Colisão de `external_event_id` entre tenants:** como a unicidade é global por fonte, se
   duas contas de tenants diferentes reportassem o mesmo id (improvável com ids globais como
   o `eventId` do Bling), o segundo seria tratado como duplicata. Revisitar se aparecer uma
   fonte com ids por conta.
2. **Conta migrando de tenant:** desativar a integração antiga e conectar a nova não move
   eventos antigos; eles ficam com o tenant original.
3. **`unknown_account` em volume:** se um lojista desconectar e o Bling continuar enviando,
   a fonte mandará eventos para sempre. O 200 evita que o Bling desative o webhook, mas
   vale um contador/alerta.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Dois tenants conectam contas diferentes da mesma fonte | Cada evento é gravado com o tenant da sua conta |
| Segundo tenant tenta conectar uma conta já ativa | Recusado (changeset com erro), nada muda |
| Tenant desconecta e outro conecta a mesma conta | Permitido; novos eventos vão para o novo tenant |
| Integração desativada e webhook assinado chega | 200 `unknown_account`, nada gravado |
| Assinatura inválida com conta desconhecida | 401, idêntico ao de conta conhecida |
| `companyId` ausente ou de tipo estranho | 200 `rejected` (`missing_account_id`) |
| Tenant B tenta reservar o evento do tenant A | `:unknown_event`, sem débito |
| `disconnect_integration` com o id de outro tenant | `{:error, :not_found}`, nada muda |

## Critérios de aceite

- **AC-1:** `connect_integration/2` cria a integração ativa; uma segunda conexão da mesma
  conta é recusada, inclusive vinda de outro tenant; depois de `disconnect_integration/2`,
  outro tenant consegue conectá-la.
- **AC-2:** Fonte não registrada, conta em branco e tenant inexistente são recusados.
- **AC-3:** Um webhook assinado de uma conta conectada grava o evento com `tenant_id`, o
  `tenant_id` no payload canônico, e enfileira o job com o `tenant_id`.
- **AC-4:** Dois tenants com contas diferentes na mesma fonte recebem cada um os seus
  eventos, e nenhum vê os do outro.
- **AC-5:** Conta sem integração, integração desativada: 200 `unknown_account`, nenhum
  evento, nenhum job.
- **AC-6:** Assinatura inválida: 401 com conta conhecida e com conta desconhecida (mesma
  resposta).
- **AC-7:** `extract_account_id/1` falho ou ausente: 200 `rejected` / `missing_account_id`.
- **AC-8:** A suíte de contrato cobre `extract_account_id/1`; fakes e Bling a implementam, e
  o Bling usa `companyId`.
- **AC-9:** `reserve/1` e `request_dispatch/1` recusam o evento de outro tenant
  (`:unknown_event`), sem débito, log ou job.
- **AC-10:** **Isolamento** (obrigatório para tabela com dado de tenant): um tenant não lê,
  lista, desativa nem altera integrações, eventos, logs ou lançamentos de outro.
- **AC-11:** O banco recusa `webhook_events` sem `tenant_id` e com `tenant_id` inexistente.
- **AC-12:** O `EventWorker` carrega o evento só pelo tenant do job.
- **AC-13:** A migration é reversível (`up` e `down` executados) e falha sem apagar dados se
  existirem eventos sem tenant.
- **AC-14:** O teste de arquitetura continua passando (nenhum módulo fora de
  `Notifiq.Integrations.*` cita o Bling).

## Rastreabilidade

- Backlog: tarefas de "multi-tenancy" e "isolamento por tenant".
- Constitution: princípios 7 (isolamento absoluto), 4 e 6 (adiado, ver non-goals).
- Spec 002 (`tenant_id` no evento canônico), Spec 003 (`companyId`), Spec 006 (reserva).

## Notas de implementação

- **Onde está:** `Notifiq.Tenants` (`connect_integration/2`, `disconnect_integration/2`,
  `list_integrations/1`, `get_integration/2`, `resolve_tenant/2`), `Tenants.Integration`,
  `Mensageria.get_webhook_event/2` e `list_webhook_events/2`, e a resolução do tenant em
  `Integrations.Ingestion`. Migrations: `create_integrations`, `add_tenant_id_to_webhook_events`
  e `add_seq_to_credit_transactions`.
- **Contrato:** o callback `extract_account_id/1` foi acrescentado ao `Source` (lib e arquivo
  normativo em `specs/002-camada-integracoes/contracts/`, idênticos). Os fakes e o Bling o
  implementam; a suíte de contrato o verifica.
- **A resposta para conta desconhecida é 200**, não 4xx: a documentação do Bling diz que
  respostas não-2xx são retentadas por dias e depois desativam o webhook.
- **Reserva:** o tenant é verificado antes do evento, então um tenant inexistente continua
  sendo `:unknown_tenant`; o evento de outro tenant é `:unknown_event`. O antigo
  `{:error, :conflict}` para evento alheio deixou de ser alcançável.
- **Defeito encontrado no caminho:** o livro-razão era ordenado por `inserted_at` com
  desempate por UUID aleatório. No Windows o relógio tem resolução grosseira, dois
  lançamentos seguidos empatavam e a ordem virava sorteio (um teste falhou 1 vez em ~6
  execuções). Foi acrescentada a coluna `seq` (`bigserial`), gerada pelo banco, e
  `list_credit_transactions/2` ordena por ela. Cinco execuções seguidas passaram depois.
- **Verificação por mutação:** ignorar o tenant do evento na reserva falha 2 testes; não
  filtrar o `disconnect_integration` por tenant falha 1; ignorar o status em
  `resolve_tenant/2` falha 4.
- **AC-13 verificado num banco descartável:** com um evento legado presente a migration do
  `tenant_id` falha com `not_null_violation`, o evento permanece e a coluna não é criada;
  depois de removê-lo a migração passa; `rollback --step 3` e nova subida funcionam.
- **Teste ao vivo em dev:** webhook assinado de uma empresa conectada → evento do tenant
  certo e job só com ids (executado); empresa desconhecida → 200 `unknown_account`; assinatura
  forjada → 401 igual nos dois casos.
- **Fica para a spec de autenticação:** o plug de isolamento das telas e a tela/API para o
  lojista conectar a conta (`connect_integration/2` é a função que elas chamarão).
