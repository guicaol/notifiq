# Specs — Notifiq

Pacote de especificações no formato Spec-Driven Development (constitution → spec → contracts),
compatível com o fluxo de agentes de codificação (GitHub Spec Kit, Claude Code, Kiro e
equivalentes).

## Como usar

1. **Leia `constitution.md` primeiro.** Ela vale para todo o projeto e não deve ser reescrita
   por uma spec individual.
2. **Cada pasta `NNN-slug/` é uma feature.** Contém `spec.md` (goal, requisitos EARS,
   non-goals, edge cases, critérios de aceite) e, quando aplicável, `contracts/` com os
   artefatos executáveis referenciados pela spec (behaviours, schemas, payloads de exemplo).
3. **Ao implementar uma spec com um agente**, forneça `constitution.md` + a pasta da spec
   inteira (incluindo `contracts/`) como contexto. Peça para o agente gerar o plano técnico e
   as tasks antes de escrever código, e validar cada critério de aceite com um teste
   correspondente antes de marcar a spec como concluída.
4. **Specs "em aberto"** (como a Spec 003) sinalizam pontos que precisam ser confirmados contra
   documentação externa antes da implementação. Não implemente os requisitos marcados como
   "A CONFIRMAR" sem antes resolver o ponto em aberto.

## Estado atual

| Spec | Título | Depende de | Status |
|---|---|---|---|
| [001](001-scaffolding-phoenix/spec.md) | Scaffolding do projeto Phoenix | — | Implementada |
| [002](002-camada-integracoes/spec.md) | Camada de abstração de integrações | 001 | Implementada |
| [003](003-adapter-bling/spec.md) | Adapter do Bling | 002 | Implementada — validar `data` com entrega real |
| [004](004-contrato-canal-saida/spec.md) | Contrato de canal de saída | 002 | Implementada |
| [005](005-adapter-twilio/spec.md) | Adapter do Twilio (SMS) | 004 | Implementada — só SMS; WhatsApp exige templates |
| [006](006-nucleo-mensageria/spec.md) | Núcleo Mensageria: crédito e idempotência | 002, 004 | Implementada |
| [007](007-worker-disparo/spec.md) | Worker de disparo, retentativas e backoff | 006 | Implementada — acionado pelo `EventWorker` desde a Spec 009 |
| [008](008-multi-tenancy/spec.md) | Multi-tenancy: resolução do tenant e isolamento | 002, 006 | Implementada — plug de isolamento espera a autenticação |
| [009](009-templates-mensagem/spec.md) | Templates de mensagem e ligação do pipeline | 007, 008 | Implementada — só SMS; a tela de templates é da Spec 011 |
| [010](010-autenticacao-painel/spec.md) | Autenticação e painel do lojista | 006, 008, 009 | Implementada — sem limitador de tentativas de login; contas criadas pelo operador |
| [011](011-telas-templates-historico-extrato/spec.md) | Telas do lojista: templates, histórico de mensagens e extrato de créditos | 006, 009, 010 | Implementada — datas em UTC; sem lista de eventos recebidos |

## Próximas specs sugeridas (ainda não escritas)

Seguindo a mesma granularidade, os próximos candidatos naturais, na ordem em que aparecem no
plano de implementação:

- **012** — Eventos que não geraram envio: lista dos eventos recebidos (hoje o resumo só os
  conta), reprocessar os `insufficient_credits` depois de uma recarga (com prazo de
  validade) e alertas dos que ficaram sem envio.
- **013** — WhatsApp: estender `OutboundMessage` com template aprovado (`ContentSid` +
  variáveis) e declarar `:whatsapp` no provider do Twilio (ver Spec 005).
- **014** — OAuth do Bling: tokens por integração, **criptografados** (Constitution,
  princípio 6) — necessário para buscar o telefone do contato, que o webhook pode não trazer.
- **015** — Limitador de tentativas de login e troca de senha pelo próprio lojista (pontos em
  aberto da Spec 010); fuso horário por tenant (ponto em aberto da Spec 011).

Cada uma deve seguir o mesmo formato: goal, user story, requisitos EARS, non-goals, edge
cases, critérios de aceite, rastreabilidade ao backlog e à constitution.

## Relação com os outros artefatos do projeto

- **Documentação técnica** (`documentacao-tecnica-saas-mensageria.html`) continua sendo a
  visão de arquitetura e negócio de alto nível — as specs aqui são o detalhamento executável
  de partes específicas dela.
- **Backlog Kanban** continua rastreando o esforço por hora; a coluna "Rastreabilidade" de
  cada spec aponta para os IDs correspondentes (`MSG-XXX`).
- Quando uma spec e a documentação técnica divergirem, **a spec vence** para o escopo que ela
  cobre — é o artefato mais granular e mais recentemente validado.
