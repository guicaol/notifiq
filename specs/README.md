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

## Próximas specs sugeridas (ainda não escritas)

Seguindo a mesma granularidade, os próximos candidatos naturais, na ordem em que aparecem no
plano de implementação:

- **004** — Contrato de canal de saída (`Notifiq.Channels.Provider`), espelhando a Spec 002
  para o lado de disparo.
- **005** — Adapter de canal Twilio (implementa `Channels.Provider`), espelhando a Spec 003.
- **006** — Núcleo `Mensageria`: consumo de crédito transacional (`Ecto.Multi`), idempotência
  ligada ao registro em `webhook_events`.
- **007** — Worker Oban de disparo, retentativas e backoff.
- **008** — Multi-tenancy: middleware/plug de isolamento por `tenant_id` e o teste de
  isolamento obrigatório (Constitution, princípio 7).

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
