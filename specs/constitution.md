# Constitution — Notifiq

> Este documento define os princípios não-negociáveis do projeto. Qualquer spec, plano ou
> implementação (humana ou gerada por agente) que conflite com este arquivo está incorreta —
> corrija a implementação, não a constitution, a menos que uma decisão explícita a atualize.

## 1. Missão

Notifiq é uma **plataforma de mensageria orientada a eventos**: conecta sistemas de origem
(CRMs, ERPs, aplicações próprias) a canais de mensageria (SMS, WhatsApp) através de um núcleo
agnóstico à origem e ao destino. Bling (origem) e Twilio (canal) são a primeira configuração —
não são o produto.

## 2. Princípios arquiteturais não-negociáveis

1. **O núcleo nunca conhece uma fonte específica.** Toda integração de entrada implementa o
   contrato `Notifiq.Integrations.Source`. Nenhum módulo fora de `Notifiq.Integrations.*` pode
   referenciar Bling, ou qualquer outro CRM, por nome.
2. **O núcleo nunca conhece um canal específico.** Toda integração de saída implementa o
   contrato `Notifiq.Channels.Provider`. Nenhum módulo fora de `Notifiq.Channels.*` pode
   referenciar Twilio, ou qualquer outro provedor, por nome.
3. **Tudo que atravessa a fronteira de um adapter vira um evento canônico.** O formato está
   definido em `specs/002-camada-integracoes/contracts/canonical_event.schema.json` e é
   versionado. Mudança de formato exige nova versão, não alteração silenciosa.
4. **Todo evento é idempotente.** A tupla `(source, external_event_id)` é única na tabela
   `webhook_events`. Reentrega do mesmo evento nunca gera um segundo disparo.
5. **Toda operação de crédito é transacional.** Débito de crédito e criação do registro de
   disparo ocorrem na mesma transação (`Ecto.Multi`), com lock para evitar condição de corrida.
6. **Nenhuma credencial em texto plano.** Tokens, API keys e segredos de qualquer integração
   são armazenados criptografados (Cloak/Ecto ou equivalente). Secrets da própria aplicação
   vivem em variáveis de ambiente via `config/runtime.exs`, nunca no código-fonte.
7. **Isolamento de tenant é absoluto.** Toda query operacional filtra por `tenant_id`. Um teste
   de isolamento entre tenants é obrigatório para qualquer tabela nova com dado de tenant.
8. **Resposta rápida, processamento assíncrono.** Endpoints de webhook respondem em até 200ms;
   todo processamento pesado é delegado a um job Oban. Falha de um job nunca derruba o endpoint
   nem afeta outro tenant.

## 3. Stack fixa

Elixir · Phoenix · Phoenix LiveView · PostgreSQL · Ecto · Oban · Req. Mudança de stack exige
uma ADR na documentação técnica, não é decisão de spec individual.

## 4. Convenções de nomenclatura

```
Notifiq.Integrations.Source          # behaviour (contrato de entrada)
Notifiq.Integrations.<Fonte>.*        # ex.: Notifiq.Integrations.Bling.*
Notifiq.Channels.Provider             # behaviour (contrato de saída)
Notifiq.Channels.<Provedor>.*         # ex.: Notifiq.Channels.Twilio.*
Notifiq.Mensageria.*                  # núcleo de domínio, agnóstico à fonte/canal
Notifiq.Mensageria.CanonicalEvent     # struct do evento normalizado
```

## 5. Convenções de qualidade

- Todo teste externo (Bling, Twilio) usa `Bypass` ou `Mox` — nenhum teste chama uma API real.
- `mix format` e `mix credo --strict` sem pendências antes de qualquer merge.
- Toda migration é reversível (`down/0` implementado ou gerada como reversível).
- Cobertura obrigatória (não negociável, independente de meta geral de cobertura) nos
  caminhos: idempotência, isolamento de tenant, transação de crédito, resiliência de worker.

## 6. Definition of Done padrão

Uma feature só está pronta quando:

- [ ] Implementação cobre todos os requisitos funcionais da spec.
- [ ] Todos os critérios de aceite da spec têm um teste automatizado correspondente.
- [ ] `mix test` passa integralmente.
- [ ] `mix credo --strict` sem pendências críticas.
- [ ] Nenhum princípio da Seção 2 foi violado.
- [ ] A spec foi atualizada se o comportamento implementado divergiu do planejado.

## 7. Organização de specs

```
specs/
  constitution.md              # este arquivo
  NNN-slug/
    spec.md                    # goal, requisitos EARS, edge cases, critérios de aceite
    contracts/                 # schemas, behaviours, payloads de exemplo
```

Specs são granulares por feature, não por fase do plano de implementação. Uma fase do plano
(ex. "Fase 4") agrupa várias specs.
