# Spec 009 — Templates de mensagem e ligação do pipeline

**Fase relacionada:** Fase de disparo — fecha o caminho webhook → mensagem
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 007 (`request_dispatch/1`), Spec 008 (tenant por evento), Spec 004/005
(provider e canal)

## Goal

Decidir **o que enviar** para cada evento recebido: o tenant configura, por tipo de evento,
um texto com variáveis, o canal e o provider; o `EventWorker` aplica esse template ao evento
e pede o disparo. Com isso o pipeline funciona de ponta a ponta — webhook assinado →
tenant → texto → crédito reservado → job → SMS — que até aqui terminava num `Logger.info`.

## User story

Como lojista, quero definir a mensagem que meu cliente recebe quando o pedido é faturado
("Olá {{nome_cliente}}, seu pedido {{numero_pedido}} foi faturado"), para que as
notificações saiam sozinhas, no meu texto, e eu saiba o que aconteceu com cada evento.

## Decisões de projeto

| Decisão | Escolha | Motivo |
|---|---|---|
| Granularidade | **Um template ativo por `(tenant, event_type)`**; ele define canal, provider e texto | A Spec 006 garante um disparo por evento (`UNIQUE(webhook_event_id)`). Enviar o mesmo evento por dois canais exigiria mudar essa chave: fica fora de escopo |
| Linguagem do template | **Só substituição** de `{{variavel}}` e `{{variavel\|padrão}}`; sem condicionais, laços ou código | O texto é escrito pelo tenant e os valores vêm de terceiros (nome do cliente); uma linguagem mais rica seria superfície de ataque sem necessidade |
| Valores | Substituição em **passada única**, sem reexpandir, higienizados | Um nome como `{{x}}` ou com quebras de linha não pode virar marcação nem atrapalhar o SMS |
| Variável ausente | Usa o padrão se houver; senão **falha a renderização** e a mensagem **não** é enviada | A Spec 003 deixa a ausência de nome para o template decidir; nunca enviar "Olá , seu pedido" |
| Resultado por evento | `webhook_events.status` registra o desfecho | Sem isso um evento sem template, sem crédito ou com texto inválido some em silêncio |
| Sem crédito | Marca o evento e **não** tenta de novo sozinho | Reprocessar eventos após uma recarga é uma funcionalidade própria (ver "Pontos em aberto") |
| WhatsApp | **Continua fora**: templates aprovados (`ContentSid`) são outro modelo | `OutboundMessage` só leva texto; a Spec 005 explica |

## Variáveis disponíveis

Todas as chaves de `context` do evento canônico (no Bling: `numero_pedido`, `nome_cliente`,
`pedido_id`, `situacao_id`) e `recipient_name`. O telefone **não** é uma variável: vai só no
campo de destino, nunca dentro do texto.

## Tipos de evento

`Notifiq.Mensageria.EventTypes` passa a existir como a lista fechada de tipos que um
template pode escolher: `order_created`, `order_invoiced`, `order_shipped`,
`auth_code_requested`, `marketing_campaign_triggered` (os do schema canônico). Um tipo novo
entra por PR.

## Requisitos funcionais (EARS)

- **FR-1:** DEVE existir a tabela `message_templates` (`tenant_id`, `event_type`, `channel`,
  `provider`, `body`, `cost`, `active`), com **no máximo um template ativo por
  `(tenant_id, event_type)`** garantido por índice único parcial.
- **FR-2:** Ao salvar, o template DEVE ser validado: `event_type` em `EventTypes`; canal
  conhecido; `provider` registrado em `Channels.Registry` **e** que suporte o canal; `body`
  não vazio, com até 1000 caracteres e sintaxe de variáveis válida; `cost` inteiro de 1 a 10.
- **FR-3:** O `tenant_id` NUNCA vem dos parâmetros; toda leitura e escrita de template DEVE
  filtrar por `tenant_id` (princípio 7).
- **FR-4:** O renderizador DEVE substituir `{{nome}}` e `{{nome|padrão}}` numa única passada,
  sem reexpandir o que foi inserido, aceitando só nomes `[a-z][a-z0-9_]*`.
- **FR-5:** Os valores DEVEM ser higienizados: caracteres de controle e quebras viram espaço,
  espaços repetidos colapsam, extremidades aparadas, no máximo 200 caracteres.
- **FR-6:** SE uma variável estiver ausente, nula ou em branco e não tiver padrão, a
  renderização DEVE falhar com `{:missing_variable, nome}`; valores que não sejam texto,
  número ou booleano falham com `{:unsupported_value, nome}`.
- **FR-7:** O `EventWorker` DEVE, para o evento do seu tenant, buscar o template ativo do
  `event_type`, renderizá-lo com o contexto do evento e chamar `Mensageria.request_dispatch/1`
  com o telefone do destinatário do evento, o canal, o provider e o custo do template.
- **FR-8:** O desfecho DEVE ser gravado em `webhook_events.status`:
  `dispatched` (reservado, inclusive duplicata), `skipped_no_template`, `render_failed`,
  `insufficient_credits` ou `invalid_request`. A gravação só sai de `received`.
- **FR-9:** SE não houver template ativo, o evento DEVE ser marcado `skipped_no_template`,
  nada reservado nem cobrado, e o job concluir normalmente.
- **FR-10:** O `EventWorker` DEVE ser idempotente: rodar de novo para o mesmo evento nunca
  cria um segundo disparo nem uma segunda cobrança (apoia-se em `request_dispatch/1`).
- **FR-11:** Falhas transitórias (`:enqueue_failed`, `:conflict`) DEVEM ser retentadas pelo
  Oban; as definitivas (`render_failed`, `insufficient_credits`, `invalid_request`) cancelam
  o job com o motivo.
- **FR-12:** Nenhum log ou erro DEVE conter o texto renderizado, o nome do cliente ou o
  telefone.

## Non-goals

- Tela ou API para o lojista editar templates (spec de autenticação e painel): aqui só as
  funções de domínio que elas chamarão.
- Mais de um canal por evento; WhatsApp e seus templates aprovados.
- Reprocessar eventos `insufficient_credits` depois de uma recarga.
- Linguagem de template com lógica; internacionalização; pré-visualização.
- Escolher o provider por país ou custo; failover entre providers.
- Validar o tamanho em segmentos de SMS (aqui só o limite de caracteres).

## Pontos em aberto

1. **Eventos perdidos por falta de crédito:** ficam `insufficient_credits` para sempre. Uma
   recarga deveria permitir reprocessá-los (talvez com um prazo de validade).
2. **Template alterado com eventos em voo:** o texto vale no momento em que o
   `EventWorker` roda, não no do recebimento do webhook.
3. **Padrões de higienização:** 200 caracteres por valor é um chute; um nome muito longo é
   truncado em silêncio.
4. **Custo em segmentos:** um SMS com acentos pode ocupar vários segmentos (e o Twilio cobra
   por segmento); o `cost` do template é fixo e informado pelo lojista.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Nome do cliente ausente e template `{{nome_cliente\|cliente}}` | Usa "cliente" |
| Nome do cliente ausente e template `{{nome_cliente}}` | `render_failed`, nada enviado nem cobrado |
| Nome do cliente `"{{numero_pedido}}"` | Entra literal; não é reexpandido |
| Nome com quebra de linha ou 500 caracteres | Colapsado em uma linha e truncado em 200 |
| Evento sem telefone do destinatário | `invalid_request`, nada cobrado |
| Dois templates ativos para o mesmo tipo | Impossível: o banco recusa |
| Template desativado | É ignorado: o evento fica `skipped_no_template` |
| Template de outro tenant para o mesmo tipo | Nunca usado |
| `EventWorker` repetido depois de reservar | `{:duplicate, _}` → `dispatched`, uma só cobrança |
| Provider do template removido da configuração depois | O disparo falha de forma permanente (`unknown_provider`) e o crédito volta |

## Critérios de aceite

- **AC-1:** Um template válido é criado, ativo, com o `tenant_id` do chamador.
- **AC-2:** São recusados: `event_type` fora da lista, provider não registrado, provider que
  não suporta o canal, corpo vazio ou grande, sintaxe inválida (`{{`, `{{ 1x }}`, `}}`
  solto), custo fora de 1 a 10 e um segundo template ativo do mesmo tipo.
- **AC-3:** O renderizador cobre substituição, padrão, espaços dentro das chaves, passada
  única, higienização, truncamento, variável ausente e valor não suportado.
- **AC-4:** `find_active/2` devolve só o template ativo do tenant; desativar o remove da
  busca e libera outro.
- **AC-5:** Evento com template: o `EventWorker` cria o log com o texto renderizado, o
  telefone do evento, o provider do template e enfileira o `DispatchWorker`; o evento fica
  `dispatched`.
- **AC-6:** Sem template ativo: `skipped_no_template`, nenhum log, nenhum débito.
- **AC-7:** Variável ausente sem padrão: `render_failed`, nenhum log, nenhum débito.
- **AC-8:** Sem crédito: `insufficient_credits`, nenhum job, saldo intacto.
- **AC-9:** Executar o `EventWorker` duas vezes (inclusive em paralelo) gera um log, uma
  cobrança e um job.
- **AC-10:** **Isolamento:** um tenant não lê, lista, altera nem desativa templates de outro;
  o template de A nunca é usado para um evento de B.
- **AC-11:** **Pipeline completo:** webhook assinado do Bling → `EventWorker` →
  `DispatchWorker` → provider: o log termina `sent`, com o texto renderizado e o crédito
  gasto uma vez.
- **AC-12:** Os logs dos cenários de falha não contêm o texto, o nome nem o telefone.
- **AC-13:** `EventTypes` lista os cinco tipos e rejeita qualquer outro.
- **AC-14:** O teste de arquitetura continua passando (o núcleo não cita Bling nem Twilio).

## Rastreabilidade

- Backlog: tarefas de "templates de mensagem" e "mapa evento → mensagem".
- Constitution: princípios 1 e 2 (o template só guarda chaves de provider), 7 (isolamento),
  8 (processamento assíncrono).
- Specs 003 (variáveis do Bling), 006 (idempotência), 007 (disparo), 008 (tenant).

## Notas de implementação

- **Onde está:** `Notifiq.Templates` (contexto, tudo filtrado por `tenant_id`),
  `Templates.MessageTemplate` (validações), `Templates.Renderer` (puro),
  `Mensageria.EventTypes`, `Mensageria.update_event_status/3` e o novo `EventWorker`.
  Migration: `create_message_templates` (índice único parcial por `(tenant_id, event_type)`
  onde `active`, e `CHECK` do custo).
- **O `EventWorker` agora fecha o caminho:** webhook → tenant → template → texto renderizado →
  `request_dispatch/1` → `DispatchWorker` → provider. Cada desfecho fica em
  `webhook_events.status`; só sai de `received`, então uma repetição não sobrescreve o
  resultado anterior.
- **Retorno do worker:** `:ok` para `dispatched` e `skipped_no_template` (resultados normais);
  `{:cancel, motivo}` para `render_failed`, `insufficient_credits` e `invalid_request`, que
  não melhoram com nova tentativa. Só `:enqueue_failed` e `:conflict` voltam como `{:error, _}`
  para o Oban repetir.
- **Higienização testada por mutação:** remover a higienização falha 6 testes do renderizador;
  fazer a variável ausente virar texto vazio falha 5; `find_active/2` sem filtro de tenant
  falha 5; permitir sobrescrever o desfecho do evento falha 2.
- **Concorrência real:** o `EventWorker` rodando 10 vezes ao mesmo tempo para o mesmo evento
  deixa 1 log, 1 job e 1 cobrança; 10 criações simultâneas de template para o mesmo tipo
  deixam exatamente um ativo.
- **Teste ao vivo em dev** (provider `twilio` sem credenciais, nada pôde sair): um webhook
  assinado do Bling virou o texto "Olá Joana Teste, seu pedido 4321 foi faturado.", o evento
  ficou `dispatched`, o disparo falhou por `missing_credentials` e o crédito voltou
  (livro-razão `purchase 3, dispatch -1, refund 1`); os dois jobs só carregam ids.
- **Cuidado ao escrever testes com caracteres invisíveis:** os de controle e bidirecionais são
  montados com `<<0x...::utf8>>`, porque os editores os convertem em caracteres reais no
  arquivo-fonte e o compilador os recusa.
