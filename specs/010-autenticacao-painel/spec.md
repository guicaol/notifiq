# Spec 010 — Autenticação e painel do lojista

**Fase relacionada:** Painel do lojista (front-end)
**Status:** Implementada (2026-10-30)
**Depende de:** Spec 008 (tenants e integrações), Spec 006 (saldo, logs), Spec 009 (eventos)

## Goal

Dar ao lojista uma porta de entrada segura — login, sessão, logout — e um painel cujo
**tenant vem da sessão autenticada, nunca de um parâmetro**, fechando a lacuna que a Spec 008
deixou ("o plug de isolamento espera a autenticação"). O painel nasce com duas telas: o
**resumo** (saldo, envios e eventos que pedem atenção) e as **integrações** (conectar e
desconectar a conta da fonte, por exemplo o Bling).

## User story

Como lojista, quero entrar com meu e-mail e senha e ver o saldo, o que foi enviado e o que
falhou, e conectar minha conta do Bling, sem nunca poder ver ou alterar dados de outro
lojista.

## Decisões de projeto

| Decisão | Escolha | Motivo |
|---|---|---|
| Usuário × tenant | Cada usuário pertence a **exatamente um** tenant (`users.tenant_id NOT NULL`); o schema permite vários usuários por tenant, mas não há convite nem papéis | O menor modelo que isola; papéis e convites são outra spec |
| Cadastro | **Sem cadastro público.** O operador cria tenant + primeiro usuário com `mix notifiq.create_account` | Não há cobrança ainda; cadastro aberto criaria contas gratuitas sem controle |
| Identidade do tenant | `Scope{user, tenant}` montado a partir do usuário da sessão, a cada requisição e a cada montagem de LiveView | O tenant nunca é lido de URL, formulário ou evento do cliente |
| Hash da senha | `Pbkdf2` (`pbkdf2_elixir`, Elixir puro) | Sem NIF para compilar no Windows; padrão aceito (SHA-512, rounds configuráveis) |
| Sessão | Token aleatório de 32 bytes no cookie assinado; o banco guarda só o **SHA-256** do token; validade absoluta de 14 dias | Um dump do banco não permite sequestrar sessões; logout e troca de senha revogam no servidor |
| Erros de login | Mensagem única para e-mail inexistente e senha errada; o tempo de resposta também não distingue (`Pbkdf2.no_user_verify/0`) | Evita enumeração de contas |
| Navegação após login | Volta para a página pedida (só caminhos locais) | Experiência normal; fechar o *open redirect* |
| Nomes de fonte na tela | Vêm do adapter (`metadata/0`), nunca escritos no painel | Constitution, princípio 1: nada fora de `Notifiq.Integrations.*` cita o Bling |
| Telefone nas telas | Mascarado (`+55 11 •••••-8888`) | O painel mostra o mínimo necessário (LGPD); o texto da mensagem não aparece nesta spec |
| Idioma | Português fixo nas telas novas, sem `gettext` | Há um único idioma; internacionalizar é outra decisão |

## Mudança de contrato

`Notifiq.Integrations.Source` ganha um **sexto callback**:

```elixir
@callback metadata() :: %{name: String.t(), account_label: String.t()}
```

`name` é como a fonte se chama para o lojista; `account_label` é o rótulo do campo em que
ele informa o identificador da conta (no Bling, o `companyId`). É puro e constante. A
validação do boot (`Registry.validate!/0`) passa a exigir também `extract_account_id/1` e
`metadata/0`, e a suíte de contrato os verifica.

## Requisitos funcionais (EARS)

### Contas e senhas

- **FR-1:** DEVEM existir as tabelas `users` (`tenant_id` NOT NULL com chave estrangeira,
  `email` único, `hashed_password`) e `user_tokens` (`user_id`, `token` único por contexto,
  `context`, `inserted_at`).
- **FR-2:** O e-mail DEVE ser guardado sem espaços nas pontas e em minúsculas, e ser único
  sem distinguir maiúsculas; DEVE ter formato `algo@algo` e no máximo 160 caracteres.
- **FR-3:** A senha DEVE ter de 12 a 128 caracteres e NUNCA ser guardada nem registrada em
  texto plano; o campo virtual `password` NÃO pode aparecer em `inspect/1` do usuário.
- **FR-4:** `Accounts.create_account/1` DEVE criar o tenant e o primeiro usuário numa única
  transação: se o usuário for inválido, o tenant não é criado.
- **FR-5:** `Accounts.get_user_by_email_and_password/2` DEVE devolver o usuário só com a
  senha correta e, para e-mail inexistente, DEVE gastar o mesmo trabalho de hash.
- **FR-6:** `Accounts.reset_password/2` DEVE trocar a senha e revogar **todas** as sessões do
  usuário.
- **FR-7:** DEVE existir `mix notifiq.create_account --tenant NOME --email E [--password P]
  [--credits N]`; sem `--password` gera uma senha aleatória e a mostra uma única vez.

### Sessão

- **FR-8:** `Accounts.generate_user_session_token/1` DEVE guardar apenas o hash do token;
  `get_user_by_session_token/1` DEVE recusar token desconhecido, adulterado ou com mais de
  14 dias.
- **FR-9:** O login DEVE renovar a sessão (anti-fixação), guardar o token e um
  `live_socket_id` derivado dele. O logout DEVE apagar o token no banco, desconectar os
  LiveViews abertos dessa sessão e limpar a sessão.
- **FR-10:** `POST /entrar` com credenciais inválidas DEVE responder com o formulário e a
  mensagem única de FR-5, sem criar sessão e sem devolver a senha digitada.
- **FR-11:** Páginas do painel sem sessão válida DEVEM redirecionar para `/entrar`,
  lembrando o caminho (somente `GET`) para depois do login; só caminhos locais (começando
  com `/` e não com `//`) são aceitos.
- **FR-12:** Quem já está autenticado e abre `/entrar` DEVE ser levado a `/painel`. `GET /`
  DEVE redirecionar para `/painel` (autenticado) ou `/entrar`.
- **FR-13:** A cada montagem de LiveView do painel o token DEVE ser revalidado: sessão
  revogada nunca monta uma tela.

### Painel

- **FR-14:** O **tenant de toda leitura e escrita do painel DEVE vir de `current_scope`**.
  Nenhum parâmetro, rota ou evento de LiveView carrega `tenant_id`.
- **FR-15 (resumo, `/painel`):** DEVE mostrar o saldo de créditos do tenant, as mensagens dos
  últimos 30 dias contadas por situação (enviadas, falhas, em andamento), a quantidade de
  eventos dos últimos 30 dias que **não geraram envio** por motivo (`insufficient_credits`,
  `render_failed`, `invalid_request`, `skipped_no_template`) e as 10 mensagens mais recentes
  com o telefone mascarado.
- **FR-16 (integrações, `/painel/integracoes`):** DEVE listar as integrações do tenant e as
  fontes disponíveis (nome e rótulo vindos de `metadata/0`), mostrar a URL do webhook a
  configurar na fonte, conectar uma conta (`Tenants.connect_integration/2`) e desconectar uma
  integração do próprio tenant (`Tenants.disconnect_integration/2`).
- **FR-17:** Conectar uma conta já ativa em **qualquer** tenant DEVE mostrar o mesmo erro
  genérico ("já está conectada"), sem revelar de quem; desconectar o id de outro tenant NÃO
  DEVE ter efeito e DEVE avisar "não encontrada".
- **FR-18:** Todas as telas autenticadas DEVEM compartilhar um layout com navegação, o nome
  do tenant, o e-mail do usuário e o botão de sair (`DELETE /sair`, protegido por CSRF).

## Non-goals

- Cadastro público, confirmação de e-mail, recuperação de senha por e-mail, troca de senha e
  de e-mail pelo próprio usuário (a troca administrativa é `reset_password/2`).
- Convite de usuários, papéis e permissões; vários tenants por usuário.
- Autenticação em dois fatores, login social, "lembrar de mim" além dos 14 dias.
- **Limite de tentativas de login** (ver pontos em aberto).
- Telas de templates, histórico completo de mensagens, extrato de créditos e recarga
  (próxima spec de front-end).
- Atualização em tempo real do resumo (a tela mostra o estado no carregamento).
- Internacionalização.

## Pontos em aberto

1. **Limite de tentativas de login.** Não existe nesta spec. Como as contas são criadas pelo
   operador e a senha tem 12+ caracteres o risco é menor, mas antes de abrir o login ao
   público é preciso um limitador por IP e por e-mail (em memória não serve com mais de um
   nó; precisa de um armazenamento compartilhado).
2. **Cookie em produção.** O cookie de sessão precisa de `secure: true` e o endpoint de
   `force_ssl` quando houver HTTPS; isso é configuração de deploy, não desta spec.
3. **Perda do operador.** Sem recuperação por e-mail, quem esquece a senha depende do
   operador (`reset_password/2`).

## Edge cases

| Cenário | Comportamento esperado |
|---|---|
| E-mail com maiúsculas ou espaços no login | Normalizado; entra normalmente |
| E-mail inexistente e senha errada | Mesma mensagem, mesmo status |
| Senha com 129+ caracteres no login | Recusada como inválida, sem custo de hash proporcional |
| Token de sessão adulterado ou apagado | Tratado como sem sessão |
| Sessão com mais de 14 dias | Tratada como sem sessão |
| Logout em uma aba com o painel aberto em outra | A outra aba é desconectada pelo servidor |
| Caminho guardado na sessão que não seja local (`//evil.example`, `/\evil`, `https://evil`) | Ignorado; vai para `/painel` (não existe parâmetro `return_to`: o caminho vem só do servidor) |
| Troca de senha com sessões abertas | Todas revogadas |
| Dois tenants conectam a mesma conta | O segundo vê "já está conectada" |
| Tenant sem nenhuma mensagem | Resumo com zeros e estado vazio, sem erro |
| Usuário cujo tenant não existe mais | Não chega a existir: a chave estrangeira impede |

## Critérios de aceite

- **AC-1:** `create_account/1` cria tenant e usuário; a senha é guardada com hash; e-mail
  duplicado (em qualquer caixa) e senha curta são recusados; se o usuário é inválido nenhum
  tenant é criado.
- **AC-2:** `get_user_by_email_and_password/2` autentica com a senha certa e devolve `nil`
  com senha errada e com e-mail inexistente; o e-mail é normalizado.
- **AC-3:** O token de sessão: o banco guarda o hash (nunca o token); token válido devolve o
  usuário; apagado, adulterado ou vencido não; `reset_password/2` revoga todas as sessões.
- **AC-4:** O banco recusa usuário sem tenant e com tenant inexistente, e e-mail duplicado.
- **AC-5:** Login correto redireciona para `/painel` com a sessão renovada; login incorreto
  mostra a mesma mensagem para e-mail inexistente e senha errada e não cria sessão.
- **AC-6:** `/painel` e `/painel/integracoes` sem sessão redirecionam para `/entrar`; depois
  do login volta à página pedida; `return_to` externo é ignorado.
- **AC-7:** Logout apaga o token, limpa a sessão e emite a desconexão do `live_socket_id`;
  usar o cookie antigo não dá acesso.
- **AC-8:** Autenticado em `/entrar` é levado a `/painel`; `GET /` redireciona conforme a
  sessão.
- **AC-9:** **Isolamento do resumo:** com dois tenants com dados diferentes, cada lojista vê
  só o seu saldo, as suas contagens e as suas mensagens; o telefone aparece mascarado.
- **AC-10:** **Isolamento das integrações:** cada lojista vê só as suas; conectar uma conta
  de outro tenant mostra o erro genérico sem vazar quem a tem; desconectar o id de outro
  tenant não altera nada.
- **AC-11:** Conectar e desconectar funcionam e atualizam a lista; a URL do webhook e o nome
  da fonte vêm do adapter.
- **AC-12:** Sessão revogada impede montar a LiveView (redireciona para `/entrar`).
- **AC-13:** `metadata/0` é verificado pela suíte de contrato e exigido pelo
  `Registry.validate!/0`.
- **AC-14:** `mix notifiq.create_account` cria a conta; sem `--password` gera uma senha que
  funciona no login.
- **AC-15:** O teste de arquitetura continua passando (o painel não cita o Bling).
- **AC-16:** O hash da senha e o campo `password` não aparecem em `inspect/1` do usuário.

## Rastreabilidade

- Backlog: tarefas de "autenticação", "layout do painel" e "conectar integração".
- Constitution: princípios 7 (isolamento absoluto), 1 (núcleo agnóstico à fonte) e 6
  (nenhuma credencial em texto plano: a senha só existe como hash).
- Spec 008 (fecha o non-goal do plug de isolamento e da tela de conexão).

## Notas de implementação

- **Onde está:** `Notifiq.Accounts` (`create_account/1`, `get_user_by_email_and_password/2`,
  `reset_password/2`, sessões), `Accounts.{User,UserToken,Scope}`, `NotifiqWeb.UserAuth` (plugs e
  `on_mount`), `SessionController`, `PainelLive.{Dashboard,Integracoes}`, `NotifiqWeb.Format`,
  `mix notifiq.create_account`. Migration `create_users_and_user_tokens` (reversível; subida,
  descida e nova subida executadas no banco de dev).
- **Contrato:** `Source.metadata/0` foi acrescentado (lib e arquivo normativo da Spec 002,
  idênticos em conteúdo). O `Registry.validate!/0` exigia só 4 callbacks; passou a exigir os 6
  (faltava `extract_account_id/1`, que a Spec 008 acrescentou sem atualizar a lista).
- **Defesa em duas camadas:** o plug `require_authenticated` barra a requisição HTTP e o
  `on_mount` revalida o token na montagem conectada (websocket). Os testes cobrem as duas
  separadamente: remover só o `on_mount` não quebra os testes de rota (o plug segura), por
  isso `UserAuthTest` chama o hook direto.
- **Armadilhas encontradas:** (1) o teste de arquitetura pegou "Bling" num texto do painel (o
  princípio 1 funcionando); (2) o layout tinha a caixa da conta duas vezes (versão móvel e
  desktop) e o LiveView recusa ids duplicados, então há uma só, reposicionada por CSS; (3) um
  campo de formulário com foco não é esvaziado pelo LiveView depois de enviar, então o campo
  tem um contêiner cujo id muda a cada sucesso.
- **Verificação por mutação (10, todas detectadas):** ignorar a validade da sessão; logout sem
  apagar o token; aceitar qualquer caminho de retorno; contagens de mensagens e de eventos sem
  filtro de tenant; troca de senha sem revogar sessões; aceitar qualquer senha; não renovar a
  sessão no login; não validar o id ao desconectar; `on_mount` deixando todos entrarem.
- **Teste ao vivo em dev:** conta criada pela mix task; login no navegador; resumo com saldo
  50; conexão de conta pela tela; webhook assinado dessa conta gerou a mensagem, que aparece
  com o telefone mascarado e situação "Falhou" (o Twilio não tem credenciais em dev; o crédito
  foi devolvido e o saldo continua 50); logout leva ao login e `/painel` volta a redirecionar.
- **Fica para a próxima spec de front-end:** templates, histórico completo e extrato de
  créditos; limitador de tentativas de login (ponto em aberto 1).
