# axon-deploy

Repositório de instalação da plataforma Axon (spec 002, US5; ADR-009, ADR-022). O `Dockerfile` constrói o core a
partir de uma tag do `axon`, instala os packs recebidos pelo build-arg `PACKS` e roda `axon packs check` no
build — pack incompatível falha o build, não a produção. O runtime não tem instalador: trocar de pack é rebuildar.

A especificação mora no `axon` (`specs/002-core-pack-runtime/`, contrato `contracts/installation.md`), onde
este repositório é o submódulo `axon-deploy/`.

## Conteúdo

| Caminho | Para quê |
|---|---|
| `Dockerfile` | estágios `core` (tag `CORE_REF` do axon), `packs` (`PACKS`, o modelo de embedding do scouting e `packs check`) e `runtime` |
| `config/packs.yaml` | packs habilitados e a configuração deles (o Qdrant e o modelo do scouting) — vai para a imagem, então o build valida o que roda |
| `docker-compose.yml` | o `axon` (perfil `persistent`), o Postgres e o Qdrant, só na rede do compose; no perfil `webui`, o Open WebUI |
| `config/assistants.yaml` | Assistants de sistema — montado em runtime, somente leitura (`interno` só para o grupo `equipe`) |
| `config/identity.yaml` | clientes do provedor de identidade da plataforma (spec 012): `open-webui` e `console`, com os endereços de retorno |
| `secrets/` | arquivos de segredo montados em `/run/secrets/axon` (a senha do admin inicial); fora do git |
| `.env.example` | modo, Postgres, chave mestra, credenciais e a seção "Com interface" (copie para `.env`, fora do git) |
| `packages/incompatible-pack/` | pack incompatível de propósito, usado só pelo teste |
| `scripts/check-build.sh` | o teste da US5: compatível builda, incompatível falha, runtime sem instalador, nomes antigos recusados |
| `scripts/dev-users.sh` | contas de desenvolvimento `ana` e `bia` (grupo `equipe`) para a prova da interface |
| `scripts/check-webui.py` | a prova da interface (008 US8): login de `ana` e `bia` pela plataforma, modelos de cada uma, uma mensagem pelo Open WebUI |

## Uso

O build lê o `axon` e o `axon-scouting` (privados) pelo agente SSH: a sua chave precisa ter acesso aos dois.

```bash
scripts/check-build.sh                 # o teste completo
cp .env.example .env                   # e preencha a seção "Sempre"
docker compose up --build -d           # axon em :8000, o Postgres e o Qdrant
docker compose run --rm axon axon keys create --subject svc:operador --group admin   # uma chave de API
```

A plataforma roda sempre no perfil `persistent` (spec 002 R43): chaves de API, contas, Assistants de usuário, conversas
e servidores MCP ficam no Postgres (volume `postgres-data`) e sobrevivem a restart. A chave mestra (`AXON_MASTER_KEY`)
sela a chave de assinatura dos tokens (ADR-033) — guarde-a junto do backup do banco. Se ela se perder, a plataforma não
sobe com a identidade ligada; `docker compose run --rm axon axon identity keys rotate --force` gera uma chave nova
e encerra todas as sessões (as pessoas entram de novo; nada mais se perde).

O pack `scouting` responde a partir do corpus indexado (`rag_first`). O corpus mora no `axon-scouting`: com um clone dele
ao lado deste repositório, a ingestão usa a CLI da própria imagem — mesma codificação na indexação e na busca:

```bash
docker compose run --rm -v ../axon-scouting/corpus:/corpus:ro axon axon-scouting-corpus ingest /corpus/corpus.yaml
docker compose run --rm axon axon-scouting-corpus status
```

Repita a ingestão quando o corpus mudar (ela reaproveita o que não mudou). O Qdrant fica no volume `qdrant-data`. Chave
do Qdrant: opcional; se usar, o mesmo valor em `QDRANT_API_KEY` e `AXON_SCOUTING_QDRANT_API_KEY` no `.env`.

Trocar ou acrescentar um pack: mudar o `PACKS` (no `Dockerfile` ou com `--build-arg`) e o `config/packs.yaml`, e
rebuildar. Trocar a versão do core: `CORE_REF` (hoje `v0.7.0-rc2`: as chaves de API e as permissões dos Assistants pela console, com rotação do segredo
(ADR-040); os nomes da Axon (ADR-037) e a marca nas páginas e
na console (ADR-038); o provedor de identidade da plataforma, a administração por grupo e a console, o custo informado pelo OpenRouter no uso — sem preço cadastrado — e a escolha de provedor na
console (ADR-035), o custo parcial visível, nenhum preço de tabela para o OpenRouter e o gráfico de uso por custo,
requisições ou tokens (ADR-036), além de `rag_first`, harness de avaliação, fila e a timeline de status no Open WebUI).

Os Assistants `geral` e `scouting` declaram `overrides` no `config/assistants.yaml`: a console troca os modelos dos dois
(e os MCPs do `geral`), sempre dentro da allowlist do YAML (`openrouter/*`), e quem usa os dois e o `interno`
(`auth`, ADR-040). Mudar o YAML de uma seção sobreposta desativa a sobreposição no deploy seguinte (ADR-032).

## Open WebUI (perfil `webui`)

A interface é o Open WebUI v0.12, configurado só por ambiente (spec 008 US8; spec 002 R37–R40, R44): o login é o da
própria plataforma (spec 012, ADR-030) — o Open WebUI é o cliente confidencial `open-webui` do `config/identity.yaml` —,
e a conexão repassa o access token de cada pessoa ao `/v1` da plataforma (`system_oauth`): cada uma vê como modelos só
os Assistants que a plataforma resolve para ela. As tarefas auxiliares (título, tags, sugestões, autocompletar,
consultas de busca) ficam desligadas, e a conexão manda `x-axon-store: false`: o histórico é do Open WebUI, e cada
mensagem é uma execução da plataforma. Ela manda também `x-axon-progress: status`: o que a execução faz aparece na
timeline de status acima da resposta. A chamada de função fica no modo legado e sem as ferramentas embutidas do Open
WebUI (`DEFAULT_MODEL_PARAMS`, `DEFAULT_MODEL_METADATA`): as capacidades vêm do Assistant, e a plataforma recusa o campo
`tools`.

Preencha no `.env` a seção "Com interface" (`COMPOSE_PROFILES=webui`, `AXON_IDENTITY_ENABLED=true`, o segredo do
cliente `open-webui`, a chave de sessão do Open WebUI e, para a prova, `DEV_USERS_PASSWORD`) e:

```bash
docker compose up -d --build
scripts/dev-users.sh             # grupo equipe; ana (sem grupo) e bia (equipe), com a senha DEV_USERS_PASSWORD
# http://localhost:3000 → "Continuar com Axon" → o formulário da plataforma → ana ou bia
python3 scripts/check-webui.py   # a prova: listas por usuário, uma mensagem como a tela manda, uma execução (200)
```

O primeiro administrador: `docker compose run --rm axon axon users create admin --email … --group admin` (a senha é
lida sem eco), ou as variáveis `AXON_BOOTSTRAP_ADMIN_*` com a senha num arquivo em `secrets/` (valem só com zero
contas). As pessoas trocam a própria senha em `<AXON_PUBLIC_URL>/oauth2/account`; senha esquecida, um admin gera uma
temporária com `axon users password <nome>`.

A sessão do Open WebUI dura 29 dias (`OPEN_WEBUI_SESSION_EXPIRES_IN`) e a da plataforma, 30: a do Open WebUI precisa
vencer antes, porque sem sessão no provedor ele não renova o token que repassa à plataforma. Se aparecer "Model '' was
not found" (lista de modelos vazia), saia do Open WebUI e entre de novo.

**Login com Google** (opcional): crie um cliente OAuth no Google com o endereço de retorno
`<AXON_PUBLIC_URL>/oauth2/google/callback`, ponha `AXON_GOOGLE_CLIENT_ID` e `AXON_GOOGLE_CLIENT_SECRET` no
`.env` e reinicie. Só entram contas já cadastradas: o e-mail verificado pelo Google precisa ser o de uma conta ativa.

### Vindo dos nomes antigos (ADR-037)

Até o core `v0.6.0-rc6`, a instalação usava os nomes de antes da Axon: projeto `agentic-deploy` (da pasta), serviço
`ai-core`, variáveis `AI_CORE_*` e `AI_SCOUTING_*`. Agora o projeto é `axon`, fixo no compose, e os volumes são outros
(`axon_postgres-data`, `axon_qdrant-data`, `axon_open-webui-data`): a instalação recomeça vazia. Não há dado a
preservar (ADR-037, item 3), e as chaves e sessões seladas com os nomes antigos não valeriam mais.

```bash
docker compose -p agentic-deploy --profile webui --profile console down   # o projeto antigo, com o nome da pasta
sed -i 's/^AI_SCOUTING_/AXON_SCOUTING_/; s/^AI_CORE_/AXON_/' .env          # nessa ordem; as comentadas, à mão
docker compose up -d --build
scripts/dev-users.sh                                                       # ou `axon users create …`
docker compose run --rm -v ../axon-scouting/corpus:/corpus:ro axon axon-scouting-corpus ingest /corpus/corpus.yaml
docker volume rm agentic-deploy_postgres-data agentic-deploy_qdrant-data agentic-deploy_open-webui-data   # quando quiser
```

Um `.env` que ainda tenha `AI_CORE_*` ou `AI_SCOUTING_*` não sobe: a plataforma e o pack recusam e dizem o nome novo de
cada variável. Um `config/identity.local.yaml` (fora do git) precisa das audiências novas, `axon` e `axon-admin`. No
Open WebUI, as contas são novas (o volume é outro); o primeiro a entrar vira o administrador da interface.

### Vindo da Fase 7 (Keycloak)

O Keycloak de desenvolvimento saiu. Os nomes de usuário continuam sendo o subject da plataforma (`user:<nome>`), então
ACL e donos já gravados seguem valendo; só a identidade no Open WebUI muda.

```bash
docker compose --profile webui down
docker volume rm agentic-deploy_keycloak-data       # o Keycloak e os dados dele
# .env: tire as AXON_OIDC_* e as KEYCLOAK_*; preencha POSTGRES_PASSWORD, AXON_MASTER_KEY e a seção "Com interface"
docker compose up -d --build
scripts/dev-users.sh                                 # ou `axon users create …` com os mesmos nomes da Fase 7
```

O Open WebUI religa as contas antigas pelo e-mail (`OAUTH_MERGE_ACCOUNTS_BY_EMAIL`); se preferir começar do zero, apague
também o volume `open-webui-data`.

Com um provedor OIDC externo em vez do da plataforma, deixe `AXON_IDENTITY_ENABLED` desligado e use as variáveis
`AXON_OIDC_*` (o access token precisa ser JWT, com a audiência da plataforma e as claims de subject e grupos que a
003 lê); os dois juntos são recusados no boot (a plataforma confia num emissor só). A fila de execuções da API
(`AXON_MAX_EXECUTIONS`, `AXON_QUEUE_SIZE`, `AXON_QUEUE_WAIT_MS`) vale para todos os clientes.

## CI

`.github/workflows/build.yml` roda `scripts/check-build.sh` em cada push, com deploy keys só de leitura nos segredos
`AGENTIC_APP_DEPLOY_KEY` (cadastrada no `axon`) e `AI_SCOUTING_DEPLOY_KEY` (no `axon-scouting`); os nomes dos segredos
são de antes do ADR-037.
