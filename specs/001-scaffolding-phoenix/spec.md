# Spec 001 — Scaffolding do projeto Phoenix

**Fase relacionada:** Fase 1 — Fundação Elixir e ambiente
**Status:** Implementada
**Depende de:** nenhuma

## Goal

Ter uma aplicação Phoenix inicializada, conectada ao PostgreSQL e verificável via
health-check, servindo de base testada para todas as features seguintes.

## User story

Como desenvolvedor, quero um projeto Phoenix inicializado e com uma forma objetiva de
verificar que está saudável, para que eu possa construir as próximas features sobre uma
fundação confiável em vez de assumir que "está tudo certo".

## Requisitos funcionais (EARS)

- **FR-1:** O sistema DEVE expor um endpoint `GET /health` que retorna HTTP 200 e o corpo
  `{"status":"ok"}` quando a aplicação está de pé e a conexão com o banco está saudável.
- **FR-2:** QUANDO a conexão com o PostgreSQL estiver indisponível, o endpoint `/health` DEVE
  retornar HTTP 503 com o corpo `{"status":"degraded","reason":"database_unreachable"}`.
- **FR-3:** O sistema DEVE carregar toda configuração sensível (URL do banco, secret_key_base,
  credenciais de qualquer serviço externo) exclusivamente de variáveis de ambiente, lidas em
  `config/runtime.exs`.
- **FR-4:** SE uma variável de ambiente obrigatória estiver ausente no boot, o sistema DEVE
  falhar o boot com uma mensagem de erro que nomeia a variável ausente — nunca deve subir
  silenciosamente com um valor default inseguro.
- **FR-5:** O sistema DEVE executar `mix ecto.migrate` sem erros contra um banco PostgreSQL
  vazio recém-criado.

## Non-goals

- Autenticação de usuário (spec futura).
- Qualquer schema de domínio (`tenants`, `webhook_events`, etc. — specs futuras).
- Multi-tenancy.
- Qualquer lógica de negócio de mensageria.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Postgres cai depois do boot | `/health` passa a responder 503 na próxima checagem, sem derrubar a aplicação |
| Variável de ambiente ausente | Boot falha com mensagem nomeando a variável |
| Múltiplas requisições simultâneas a `/health` | Cada uma verifica a conexão de forma independente, sem cache stale |

## Critérios de aceite

- **AC-1:** `mix phx.server` inicia sem erros com o conjunto mínimo de variáveis de ambiente
  definido (`DATABASE_URL`, `SECRET_KEY_BASE`).
- **AC-2:** `curl -i localhost:4000/health` retorna `200` e o corpo `{"status":"ok"}`.
- **AC-3:** Com o processo do PostgreSQL parado, a mesma chamada retorna `503` com o corpo
  de degradação especificado em FR-2.
- **AC-4:** Remover `DATABASE_URL` do ambiente e tentar iniciar a aplicação resulta em falha
  de boot com mensagem contendo o nome da variável.
- **AC-5:** Existe um teste ExUnit (`HealthControllerTest`) cobrindo os casos de AC-2 e AC-3,
  usando um mock/stub de conexão para simular a indisponibilidade sem depender de derrubar o
  Postgres real durante o `mix test`.

## Rastreabilidade

- Backlog: `MSG-004` (Criação do projeto Phoenix), `MSG-001` a `MSG-003` (fundamentos de
  Elixir, pré-requisito de conhecimento, não de código).
- Constitution: princípio 6 (secrets), princípio 8 (resposta rápida — aqui aplicado ao boot).
