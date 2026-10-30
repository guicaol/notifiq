# Spec 011 — Telas do lojista: templates, histórico de mensagens e extrato de créditos

**Fase relacionada:** Painel do lojista (front-end), segunda parte
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 009 (templates), Spec 006 (mensagens e livro-razão), Spec 010 (painel e sessão)

## Goal

Dar ao lojista as três telas que faltam para operar sozinho: **escrever e ativar os
templates** (hoje só o operador consegue, pelo console), **ver cada mensagem** que a
plataforma enviou em nome dele e **entender para onde foram os créditos**. Nada de novo na
regra de negócio: as telas só chamam o domínio das Specs 006 e 009, sempre com o tenant da
sessão.

## User story

Como lojista, quero escrever o texto que meu cliente recebe quando o pedido é faturado,
ver como ele fica antes de ativá-lo, achar depois a mensagem de um cliente e saber por que
ela falhou, e conferir no extrato quando meus créditos entraram e saíram.

## Decisões de projeto

| Decisão | Escolha | Motivo |
|---|---|---|
| Quais variáveis existem | Cada fonte as declara em `metadata/0` (`variables`), e o núcleo soma `recipient_name` | Princípio 1: o painel não pode saber que o Bling chama o campo de `numero_pedido`. Sem isso o lojista escreve às cegas |
| Variável desconhecida | **O painel recusa salvar** | Sem padrão, o evento falharia em `render_failed` todas as vezes; com padrão, usaria o padrão em silêncio. Um erro de digitação (`{{nome}}`) deve aparecer na hora, não depois, num contador do resumo |
| A regra fica no painel, não no domínio | `Templates.create_template/2` continua tolerante (Spec 009) | O domínio não deve depender do registro de fontes; a regra "só variáveis conhecidas" é uma política da tela |
| Pré-visualização | Texto renderizado com **valores de exemplo** das fontes, nunca dados de clientes reais | Nenhum dado pessoal na tela de edição; o exemplo é o mesmo que a fonte declarou |
| Provedor e canal | Um único campo "como enviar" listando os pares **registrados** (`provider:canal`); o provedor aparece pela chave com que foi registrado, o painel não o nomeia | Impede a combinação inválida (canal que o provedor não suporta) e nunca converte texto da tela em átomo; o princípio 2 vale também para os rótulos |
| Tipo de evento | Na criação só aparecem tipos **sem** template ativo; na edição o tipo é fixo | A Spec 009 permite um ativo por tipo; a tela evita oferecer o que o banco recusaria |
| Excluir template | **Não existe**; só desativar | As mensagens antigas foram geradas por ele; apagar não traz benefício e perde o histórico |
| Trocar o template ativo | Desativar o atual e depois ativar o outro (duas ações) | Fazer isso numa transação exige uma função nova no domínio; fica como melhoria |
| Texto da mensagem | **Aparece só no detalhe** de uma mensagem, o telefone continua **mascarado** em todas as telas | O texto é do próprio lojista, mas leva o nome do cliente: só aparece quando ele abre aquela mensagem (a Spec 010 não mostrava o texto em tela nenhuma) |
| Paginação | **Por cursor** (`inserted_at`, `id` / `seq`), 25 por vez, botão "Carregar mais"; o cursor fica no servidor | `OFFSET` pula ou repete itens quando entram mensagens novas, e um cursor vindo do navegador seria mais uma entrada para validar |
| Saldo após cada lançamento | Calculado a partir do saldo atual, na mesma consulta | O extrato precisa fechar com o saldo mostrado, mesmo se o saldo inicial não tiver lançamento |
| Fuso horário | Datas absolutas em **UTC**, escritas como tal | Ainda não existe fuso por tenant; mostrar UTC sem avisar enganaria |
| Rótulos em português | Num módulo só (`NotifiqWeb.Labels`) | Situação, motivo de falha, tipo de evento e motivo de lançamento aparecem em várias telas |

## Mudança de contrato

`Notifiq.Integrations.Source.metadata/0` ganha a chave `variables`:

```elixir
@callback metadata() :: %{
            name: String.t(),
            account_label: String.t(),
            variables: [%{name: String.t(), label: String.t(), example: String.t()}]
          }
```

`name` é o nome da chave em `context` do evento canônico (`[a-z][a-z0-9_]*`), `label` como
o lojista a conhece e `example` o valor usado na pré-visualização. A suíte de contrato passa
a verificar a forma da lista e que os nomes não se repetem. `Registry.describe_all/0` devolve
a chave junto com as outras.

## Requisitos funcionais (EARS)

### Navegação e isolamento

- **FR-1:** O painel DEVE ter as rotas `/painel/mensagens`, `/painel/mensagens/:id`,
  `/painel/templates`, `/painel/templates/novo`, `/painel/templates/:id/editar` e
  `/painel/creditos`, dentro da sessão autenticada, e o menu lateral DEVE listar, nesta ordem,
  Resumo, Mensagens, Templates, Créditos e Integrações, destacando a página atual.
- **FR-2:** O tenant de toda leitura e escrita DEVE vir de `current_scope`. Um `id` na URL ou
  no evento DEVE ser convertido e procurado **dentro do tenant**; o de outro tenant, o
  inexistente e o malformado DEVEM dar o mesmo resultado ("não encontrado"), sem revelar que
  existe.

### Variáveis

- **FR-3:** `Templates.available_variables/0` DEVE devolver `recipient_name` (nome do
  destinatário, do núcleo) seguido das variáveis declaradas pelas fontes registradas, sem
  repetir nomes (vale a primeira).

### Templates

- **FR-4 (lista):** `/painel/templates` DEVE mostrar os cinco tipos de evento, na ordem de
  `EventTypes`, cada um com o template ativo (texto renderizado com os exemplos, "como
  enviar", custo) ou o aviso de que **não há template e os eventos desse tipo não geram
  mensagem**, com o atalho de criação. Os templates desativados do tipo aparecem abaixo dele.
- **FR-5 (formulário):** Criar e editar DEVEM oferecer: tipo do evento (só na criação, só os
  tipos sem template ativo), como enviar, texto (até 1000 caracteres) e custo em créditos
  (1 a 10). `?tipo=` pré-seleciona um tipo e um valor inválido é ignorado.
- **FR-6:** O formulário DEVE listar as variáveis disponíveis (nome e rótulo) e, ao clicar em
  uma, inserir `{{nome}}` onde está o cursor do texto.
- **FR-7 (pré-visualização):** A cada alteração o formulário DEVE mostrar o texto renderizado
  com os exemplos e o número de caracteres. Texto que não renderiza (sintaxe inválida ou
  variável sem exemplo e sem padrão) DEVE mostrar um aviso no lugar do texto, sem impedir a
  digitação.
- **FR-8:** Ao salvar, o painel DEVE recusar variável que não esteja em
  `available_variables/0`, nomeando as variáveis, e traduzir os demais erros da validação
  (Spec 009, FR-2) para português. Nada é gravado enquanto houver erro.
- **FR-9:** O navegador NÃO DEVE conseguir definir `tenant_id`, `active` nem, na edição, o
  tipo do evento: o painel repassa ao domínio só `event_type` (criação), `provider`, `channel`,
  `body` e `cost`.
- **FR-10:** O painel DEVE ativar e desativar templates do tenant. Ativar um tipo que já
  tem outro template ativo DEVE avisar que é preciso desativar o atual primeiro e não alterar
  nada.

### Mensagens

- **FR-11 (lista):** `/painel/mensagens` DEVE listar as mensagens do tenant, da mais nova
  para a mais antiga, com o telefone **mascarado**, canal, situação, créditos e quando, 25
  por vez, com "Carregar mais" enquanto houver mais. O filtro `?situacao=` aceita `sent`,
  `in_progress` e `failed` (as mesmas três faixas do resumo); outro valor equivale a "todas".
  Trocar o filtro recomeça a lista.
- **FR-12 (paginação):** A paginação DEVE ser por cursor `(inserted_at, id)`: nenhuma
  mensagem se repete nem é pulada, mesmo com horários iguais ou mensagens novas chegando.
- **FR-13 (detalhe):** `/painel/mensagens/:id` DEVE mostrar a situação, o texto enviado, o
  destinatário mascarado, canal e provedor, custo, tentativas, datas em UTC, o tipo do evento
  que a originou e o nome da fonte, o código da mensagem no provedor (quando existe) e os
  lançamentos de crédito da mensagem (débito e, se houve, estorno). Para falha ou envio sem confirmação DEVE explicar o motivo em
  português e o que aconteceu com o crédito.
- **FR-14:** O detalhe NÃO DEVE exibir o telefone completo, o identificador do evento da
  fonte nem o payload bruto.

### Créditos

- **FR-15 (extrato):** `/painel/creditos` DEVE mostrar o saldo atual e os lançamentos do
  tenant, do mais novo para o mais antigo, com o motivo em português, o valor com sinal, o
  **saldo após o lançamento** e quando, 25 por vez, paginado por `seq`. O primeiro saldo
  após o lançamento DEVE ser igual ao saldo atual do tenant e cada linha DEVE ser coerente com
  a seguinte (`saldo_após − valor = saldo_após da linha de baixo`).
- **FR-16:** Lançamentos ligados a uma mensagem DEVEM apontar para o detalhe dela.
- **FR-17:** A tela NÃO DEVE oferecer recarga: indica que a recarga é feita por quem
  administra a plataforma.

### Resumo

- **FR-18:** O resumo DEVE ganhar atalhos para as novas telas: extrato (no cartão de
  saldo), todas as mensagens, mensagens com falha e templates (no aviso de "Sem template").

## Non-goals

- Excluir templates, duplicar, histórico de versões, trocar o ativo numa só ação.
- Lista de **eventos** recebidos e reprocessamento dos que ficaram sem envio (Spec 012).
- Recarga e compra de créditos, notas fiscais, exportação do extrato.
- Busca por telefone ou texto; filtro por data; contagem total (a lista é por cursor).
- Reenviar uma mensagem manualmente.
- Fuso horário do lojista; formatação de datas por idioma.
- Tempo real: as telas mostram o estado no carregamento (a lista não se atualiza sozinha).
- Estimar segmentos de SMS e o custo real (ponto em aberto 4 da Spec 009).

## Pontos em aberto

1. **Variáveis por tipo de evento.** Hoje as variáveis são por fonte; um tipo como
   `auth_code_requested` poderia ter outras. O contrato aceita ampliar `variables` depois.
2. **Fuso horário** do lojista: as datas absolutas estão em UTC.
3. **Template alterado com eventos em voo:** continua valendo o texto no momento em que o
   `EventWorker` roda (Spec 009, ponto 2); a tela não avisa.
4. **Segmentos de SMS:** a tela conta caracteres, não segmentos; acentos do português tiram
   o SMS do alfabeto GSM e reduzem o tamanho de cada segmento.

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| Todos os tipos já têm template ativo | A criação diz isso e leva de volta à lista |
| `/painel/templates/novo?tipo=inexistente` | Ignora o valor |
| Template de outro tenant em `/editar` | Volta para a lista com "Template não encontrado." |
| `event_type` de um tipo já ativo, forjado no envio | Erro "já existe um template ativo", nada gravado |
| `{{nome}}` num texto sem variável `nome` | Recusa e cita `nome` |
| `{{nome\|cliente}}` com `nome` desconhecido | Também recusa: o padrão esconderia um erro |
| Texto só com espaços | "Preencha este campo." |
| Texto de 1001 caracteres | Recusado, com o limite |
| Pré-visualização de `{{numero_pedido}}` sem fonte registrada | Aviso "variável sem exemplo" |
| Provedor do template deixou de existir | O campo "como enviar" fica vazio e pede para escolher |
| Duas pessoas ativam o mesmo tipo ao mesmo tempo | O índice único do banco recusa uma delas |
| Mensagem de outro tenant ou id malformado | "Mensagem não encontrada." e volta à lista |
| Duas mensagens com o mesmo `inserted_at` na fronteira da página | Nenhuma se repete nem some |
| `?situacao=falhas` (valor desconhecido) | Mostra todas |
| Tenant sem mensagens ou sem lançamentos | Estado vazio, sem erro |
| Saldo inicial sem lançamento correspondente | O extrato fecha com o saldo atual; a linha mais antiga mostra o saldo que sobrou |
| Mensagem `unconfirmed` | Explica que o crédito foi mantido porque o envio pode ter saído |

## Critérios de aceite

- **AC-1:** Todas as novas rotas redirecionam para `/entrar` sem sessão; o menu tem as cinco
  entradas e destaca a atual.
- **AC-2:** A lista de templates mostra os cinco tipos; um tipo com template ativo mostra o
  texto renderizado e o custo; um sem template mostra o aviso e o atalho de criação;
  templates desativados aparecem. **Isolamento:** nunca aparece template de outro tenant.
- **AC-3:** Criar um template pelo formulário o grava ativo, com o tenant da sessão; enviar
  `tenant_id` ou `active` forjados não tem efeito.
- **AC-4:** Os erros são mostrados em português: texto vazio, grande demais, sintaxe inválida,
  custo fora de 1 a 10, como enviar inválido, variável desconhecida (com o nome). Nada é
  gravado.
- **AC-5:** Tipo que já tem ativo não aparece na criação; forjar o tipo dá erro e mantém um só
  ativo.
- **AC-6:** Editar altera texto, custo e como enviar; o tipo não muda mesmo se enviado; o
  template de outro tenant não abre.
- **AC-7:** Desativar e ativar funcionam; ativar com outro ativo avisa e não altera; o id de
  outro tenant ou malformado é "não encontrado".
- **AC-8:** A pré-visualização muda ao digitar, usa os exemplos das fontes, mostra aviso para
  texto inválido e jamais usa dados de eventos reais.
- **AC-9:** As variáveis do formulário vêm de `available_variables/0`; `recipient_name`
  aparece primeiro e não há repetidas.
- **AC-10:** A lista de mensagens mostra só as do tenant, mascaradas, filtra pelas três faixas,
  ignora filtro inválido e carrega mais sem repetir nem pular, inclusive com horários iguais.
- **AC-11:** O detalhe mostra o texto e os lançamentos da mensagem, explica a falha em
  português, e é "não encontrado" para outro tenant, id inexistente e malformado. Não mostra
  o telefone inteiro.
- **AC-12:** O extrato mostra só o tenant, com saldo após cada lançamento coerente com o saldo
  atual e entre linhas, pagina por `seq` e liga os lançamentos às mensagens.
- **AC-13:** O resumo tem os atalhos de FR-18.
- **AC-14:** A suíte de contrato verifica `variables`; `describe_all/0` as devolve; o teste de
  arquitetura continua passando (nem as telas nem os rótulos citam fonte ou provedor).
- **AC-15:** `Mensageria.page_message_logs/2` e `page_credit_transactions/2` filtram por
  tenant, respeitam o cursor e o limite máximo.

## Rastreabilidade

- Backlog: "tela de templates", "histórico de envios" e "extrato de créditos".
- Constitution: princípios 1 e 2 (rótulos e variáveis vêm dos adapters, nenhum nome de fonte ou
  provedor fora do seu espaço), 7 (isolamento), 6 (a tela nunca mostra credenciais).
- Specs 006 (livro-razão), 009 (templates e renderizador), 010 (painel, `Format`).

## Notas de implementação

- **Onde está:** `PainelLive.{Mensagens,Mensagem,Creditos,Templates,TemplateForm}`,
  `Mensageria.{page_message_logs,page_credit_transactions,list_credit_transactions_for_log}`,
  `Templates.{available_variables,unknown_variables,preview,change_template}`,
  `NotifiqWeb.Labels` (as palavras do painel), `NotifiqWeb.PainelComponents` (selo de situação,
  balão de mensagem, estado vazio), `Format.{datetime,signed}` e um manipulador `phx:insert`
  em `app.js` (insere a variável onde está o cursor). Sem migration: as consultas usam os
  índices `(tenant_id, inserted_at)` e `seq` que já existiam.
- **Contrato:** `metadata/0` ganhou `variables` (lib e arquivo normativo da Spec 002, idênticos).
  O `Registry.validate!/0` agora também confere a forma do `metadata/0`, porque uma chave
  faltando só quebraria na tela de templates. A suíte de contrato ganhou dois testes: a forma
  e a unicidade das variáveis e, o mais útil, **que o evento que o adapter produz carrega cada
  variável que ele declara** (pegou o fake da "outra fonte", que declarava variáveis que não
  emitia).
- **Defesa em profundidade no formulário:** o painel só repassa ao domínio `event_type` (na
  criação), `provider`, `channel`, `body` e `cost`; `provider` e `channel` vêm do par
  escolhido e valores digitados à mão são descartados; todo valor que não seja texto vira
  vazio (um mapa no campo do texto derrubava a renderização da própria página). Custo em
  branco é pedido de novo em vez de cair no padrão (o `cast` do Ecto trata "" como "sem
  mudança").
- **Armadilha:** um `<.bubble>` com o texto num *slot* mostrava as quebras de linha e a
  indentação do HEEx dentro do balão (`whitespace-pre-line`); o texto agora é um atributo.
- **Verificação por mutação (20, todas detectadas; uma sobreviveu e virou teste):** página de
  mensagens sem filtro de tenant; cursor que ignora empates de `inserted_at`; página sem a
  linha extra (nunca há "próxima"); saldo corrido somando em vez de subtrair; extrato sem
  partir do saldo do tenant; página do extrato sem filtro de tenant (**sobreviveu**: só a
  primeira página era testada com outro tenant; agora há um teste das páginas seguintes);
  lançamentos da mensagem sem filtro de tenant; id malformado chegando à consulta; telefone
  inteiro no detalhe; faixa "Falhas" sem `unconfirmed`; `provider`/`channel` digitados à mão
  aceitos; tipo editável; variáveis desconhecidas não conferidas; custo em branco aceito;
  variáveis repetidas; `unknown_variables/1` sempre vazio; código desconhecido mostrado cru;
  `validate!/0` sem conferir `metadata/0`; botão "Ativar" que desativa; atalho de falhas
  sempre visível.
- **Teste ao vivo em dev** (tenant descartável com 32 mensagens, 2 templates e 44 lançamentos,
  removido depois): a lista de templates mostrou o exemplo renderizado; no formulário, o botão
  de variável inseriu `{{numero_pedido}}` onde estava o cursor e a pré-visualização acompanhou
  a digitação; `{{nome}}` foi recusada com o nome da variável e o aviso na pré-visualização; o
  template válido foi criado e apareceu ativo; a lista de mensagens filtrou por "Falhas"; o
  detalhe de uma mensagem com número inválido explicou o motivo e o estorno; o extrato fechou
  em 80 na compra inicial e "Carregar mais" trouxe as 44 linhas sem repetir. Nenhuma das cinco
  páginas tem rolagem horizontal em 375 px.
- **Não verificado em navegador:** o modo escuro das novas telas (usam os mesmos tokens do
  restante do painel).
