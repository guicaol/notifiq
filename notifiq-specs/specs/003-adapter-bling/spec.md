# Spec 003 — Adapter do Bling

**Fase relacionada:** Fase 4 — Abstração de integrações + ingestão
**Status:** Rascunho — **contém itens a confirmar na documentação oficial do Bling antes da
implementação (ver Seção "Pontos em aberto")**
**Depende de:** Spec 002 (camada de abstração de integrações)

## Goal

Implementar `Notifiq.Integrations.Source` para o Bling, primeira fonte suportada pela
plataforma, traduzindo notificações de mudança de status de pedido em eventos canônicos.

## User story

Como lojista que usa o Bling, quero que mudanças de status no meu pedido dispare uma
notificação automática ao meu cliente, para que eu não precise avisá-lo manualmente a cada
etapa.

## Requisitos funcionais (EARS)

- **FR-1:** O módulo `Notifiq.Integrations.Bling` DEVE implementar
  `Notifiq.Integrations.Source` por completo (validado pela suíte de contrato da Spec 002,
  AC-6).
- **FR-2:** `source_key/0` DEVE retornar `:bling`.
- **FR-3:** `verify_authenticity/2` DEVE validar o mecanismo de autenticidade oferecido pelo
  Bling **[A CONFIRMAR — ver Pontos em aberto]** usando comparação resistente a timing attack.
- **FR-4:** `extract_event_id/1` DEVE retornar um identificador estável presente no payload do
  Bling **[A CONFIRMAR — campo exato a identificar na documentação oficial]**.
- **FR-5:** `parse/1` DEVE mapear os códigos de situação de pedido do Bling para os
  `event_type` canônicos suportados nesta primeira versão:
  - código `9` ("Atendido") → `"order_invoiced"`
  - código a confirmar ("Em rota de entrega" ou equivalente) → `"order_shipped"`
- **FR-6:** QUANDO o código de situação do Bling não corresponder a nenhum mapeamento
  conhecido, `parse/1` DEVE retornar `{:ok, :ignore}`.
- **FR-7:** `parse/1` DEVE normalizar o telefone do destinatário para E.164, assumindo DDI
  `+55` quando ausente no payload.
- **FR-8:** SE o telefone não puder ser normalizado (dígitos insuficientes após remover
  caracteres não numéricos, ou campo ausente), `parse/1` DEVE retornar
  `{:error, :invalid_phone}`.
- **FR-9:** `parse/1` DEVE popular o campo `context` do evento canônico com, no mínimo,
  `numero_pedido` e `nome_cliente`, para uso posterior na renderização do template de
  mensagem.

## Non-goals

- Suporte a eventos do Bling além dos mapeados em FR-5 nesta primeira versão.
- Suporte a qualquer outro ERP (cada um recebe sua própria spec de adapter, seguindo este
  mesmo padrão).
- Lógica de qual mensagem enviar para cada `event_type` (responsabilidade do contexto
  `Mensageria` e da tabela `message_templates`, fora desta spec).

## Pontos em aberto (bloqueiam FR-3 e FR-4)

Estes pontos precisam ser confirmados na documentação oficial do Bling **antes** de
implementar `verify_authenticity/2` e `extract_event_id/1`. Não assumir um mecanismo por
analogia com outros provedores.

1. **Mecanismo de autenticidade:** o Bling oferece assinatura HMAC no corpo, token estático em
   header, allowlist de IP, ou outro mecanismo? Isso determina a implementação completa de
   `verify_authenticity/2`.
2. **Campo de identificador de evento:** qual campo do payload de webhook do Bling é estável e
   único por notificação (candidato: `idNotificacao` ou equivalente — nome exato a confirmar)?
3. **Lista completa de códigos de situação:** confirmar o código exato correspondente a "saiu
   para entrega" (usado como exemplo no FR-5, mas não confirmado).

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Telefone com 8 dígitos (fixo) vs 9 dígitos (celular) | Ambos aceitos; normalização não assume presença do 9º dígito |
| Telefone com DDI já presente (`+5511...`) | Não duplicar o `+55` |
| Campo de telefone ausente no payload | `{:error, :invalid_phone}`, não `{:ok, :ignore}` — é um payload que deveria ser processável mas está incompleto |
| Nome do cliente ausente | `context.nome_cliente` fica `nil`; não é motivo para erro — o template decide como lidar com ausência de nome |
| Código de situação desconhecido/novo (Bling adiciona um status novo) | `{:ok, :ignore}`, com log de nível `info` (não `error`) registrando o código não mapeado, para permitir mapear no futuro |

## Critérios de aceite

- **AC-1:** Payload de exemplo ([`contracts/bling_webhook_sample.json`](contracts/bling_webhook_sample.json))
  com código `9` resulta em `CanonicalEvent` com `event_type: "order_invoiced"`.
- **AC-2:** Payload com um código de situação não mapeado resulta em `{:ok, :ignore}` e um log
  de nível `info`.
- **AC-3:** Telefone `"11999998888"` é normalizado para `"+5511999998888"`.
- **AC-4:** Telefone `"123"` resulta em `{:error, :invalid_phone}`.
- **AC-5:** Uma assinatura/token inválido resulta em `{:error, :invalid_signature}` (ou código
  de erro equivalente ao mecanismo confirmado) em `verify_authenticity/2`.
- **AC-6:** O módulo `Notifiq.Integrations.Bling` passa integralmente pela suíte de contrato
  de adapter definida na Spec 002 (AC-6).
- **AC-7:** `context.numero_pedido` e `context.nome_cliente` estão presentes e corretos no
  evento canônico gerado a partir do payload de exemplo.

## Rastreabilidade

- Backlog: tarefas da Fase 4 relativas a "Validação de autenticidade", "Pattern matching no
  payload do Bling", "Normalização de telefone".
- Constitution: princípios 1, 3, 6.
- Documentação técnica: Seção 7.2 (Bling ERP).
