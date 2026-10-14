# agentic-deploy

Repositório de instalação da plataforma Agentic AI (spec 002, US5; ADR-009, ADR-022). O `Dockerfile` constrói o core a
partir de uma tag do `agentic-app`, instala os packs recebidos pelo build-arg `PACKS` e roda `ai-core packs check` no
build — pack incompatível falha o build, não a produção. O runtime não tem instalador: trocar de pack é rebuildar.

A especificação mora no `agentic-app` (`specs/002-core-pack-runtime/`, contrato `contracts/installation.md`), onde
este repositório é o submódulo `agentic-deploy/`.

## Conteúdo

| Caminho | Para quê |
|---|---|
| `Dockerfile` | estágios `core` (tag `CORE_REF` do agentic-app), `packs` (`PACKS`, o modelo de embedding do scouting e `packs check`) e `runtime` |
| `config/packs.yaml` | packs habilitados e a configuração deles (o Qdrant e o modelo do scouting) — vai para a imagem, então o build valida o que roda |
| `docker-compose.yml` | o `ai-core` (perfil `persistent`), o Postgres e o Qdrant, só na rede do compose; no perfil `webui`, o Open WebUI |
| `config/assistants.yaml` | Assistants de sistema — montado em runtime, somente leitura (`interno` só para o grupo `equipe`) |
| `config/identity.yaml` | clientes do provedor de identidade da plataforma (spec 012): `open-webui` e `console`, com os endereços de retorno |
| `secrets/` | arquivos de segredo montados em `/run/secrets/ai-core` (a senha do admin inicial); fora do git |
| `.env.example` | modo, Postgres, chave mestra, credenciais e a seção "Com interface" (copie para `.env`, fora do git) |
| `packages/incompatible-pack/` | pack incompatível de propósito, usado só pelo teste |
| `scripts/check-build.sh` | o teste da US5: compatível builda, incompatível falha, runtime sem instalador |
| `scripts/dev-users.sh` | contas de desenvolvimento `ana` e `bia` (grupo `equipe`) para a prova da interface |
| `scripts/check-webui.py` | a prova da interface (008 US8): login de `ana` e `bia` pela plataforma, modelos de cada uma, uma mensagem pelo Open WebUI |

## Uso

O build lê o `agentic-app` e o `ai-scouting` (privados) pelo agente SSH: a sua chave precisa ter acesso aos dois.

```bash
scripts/check-build.sh                 # o teste completo
cp .env.example .env                   # e preencha a seção "Sempre"
docker compose up --build -d           # ai-core em :8000, o Postgres e o Qdrant
docker compose run --rm ai-core ai-core keys create --subject svc:operador --group admin   # uma chave de API
```

A plataforma roda sempre no perfil `persistent` (spec 002 R43): chaves de API, contas, Assistants de usuário, conversas
e servidores MCP ficam no Postgres (volume `postgres-data`) e sobrevivem a restart. A chave mestra (`AI_CORE_MASTER_KEY`)
sela a chave de assinatura dos tokens (ADR-033) — guarde-a junto do backup do banco. Se ela se perder, a plataforma não
sobe com a identidade ligada; `docker compose run --rm ai-core ai-core identity keys rotate --force` gera uma chave nova
e encerra todas as sessões (as pessoas entram de novo; nada mais se perde).

O pack `scouting` responde a partir do corpus indexado (`rag_first`). O corpus mora no `ai-scouting`: com um clone dele
ao lado deste repositório, a ingestão usa a CLI da própria imagem — mesma codificação na indexação e na busca:

```bash
docker compose run --rm -v ../ai-scouting/corpus:/corpus:ro ai-core ai-scouting-corpus ingest /corpus/corpus.yaml
docker compose run --rm ai-core ai-scouting-corpus status
```

Repita a ingestão quando o corpus mudar (ela reaproveita o que não mudou). O Qdrant fica no volume `qdrant-data`. Chave
do Qdrant: opcional; se usar, o mesmo valor em `QDRANT_API_KEY` e `AI_SCOUTING_QDRANT_API_KEY` no `.env`.

Trocar ou acrescentar um pack: mudar o `PACKS` (no `Dockerfile` ou com `--build-arg`) e o `config/packs.yaml`, e
rebuildar. Trocar a versão do core: `CORE_REF` (hoje `v0.6.0-rc2`: o provedor de identidade da plataforma e a
administração por grupo, além de `rag_first`, harness de avaliação, fila e a timeline de status no Open WebUI).

## Open WebUI (perfil `webui`)

A interface é o Open WebUI v0.12, configurado só por ambiente (spec 008 US8; spec 002 R37–R40, R44): o login é o da
própria plataforma (spec 012, ADR-030) — o Open WebUI é o cliente confidencial `open-webui` do `config/identity.yaml` —,
e a conexão repassa o access token de cada pessoa ao `/v1` da plataforma (`system_oauth`): cada uma vê como modelos só
os Assistants que a plataforma resolve para ela. As tarefas auxiliares (título, tags, sugestões, autocompletar,
consultas de busca) ficam desligadas, e a conexão manda `x-ai-core-store: false`: o histórico é do Open WebUI, e cada
mensagem é uma execução da plataforma. Ela manda também `x-ai-core-progress: status`: o que a execução faz aparece na
timeline de status acima da resposta. A chamada de função fica no modo legado e sem as ferramentas embutidas do Open
WebUI (`DEFAULT_MODEL_PARAMS`, `DEFAULT_MODEL_METADATA`): as capacidades vêm do Assistant, e a plataforma recusa o campo
`tools`.

Preencha no `.env` a seção "Com interface" (`COMPOSE_PROFILES=webui`, `AI_CORE_IDENTITY_ENABLED=true`, o segredo do
cliente `open-webui`, a chave de sessão do Open WebUI e, para a prova, `DEV_USERS_PASSWORD`) e:

```bash
docker compose up -d --build
scripts/dev-users.sh             # grupo equipe; ana (sem grupo) e bia (equipe), com a senha DEV_USERS_PASSWORD
# http://localhost:3000 → "Continuar com Agentic" → o formulário da plataforma → ana ou bia
python3 scripts/check-webui.py   # a prova: listas por usuário, uma mensagem como a tela manda, uma execução (200)
```

O primeiro administrador: `docker compose run --rm ai-core ai-core users create admin --email … --group admin` (a senha é
lida sem eco), ou as variáveis `AI_CORE_BOOTSTRAP_ADMIN_*` com a senha num arquivo em `secrets/` (valem só com zero
contas). As pessoas trocam a própria senha em `<AI_CORE_PUBLIC_URL>/oauth2/account`; senha esquecida, um admin gera uma
temporária com `ai-core users password <nome>`.

A sessão do Open WebUI dura 29 dias (`OPEN_WEBUI_SESSION_EXPIRES_IN`) e a da plataforma, 30: a do Open WebUI precisa
vencer antes, porque sem sessão no provedor ele não renova o token que repassa à plataforma. Se aparecer "Model '' was
not found" (lista de modelos vazia), saia do Open WebUI e entre de novo.

**Login com Google** (opcional): crie um cliente OAuth no Google com o endereço de retorno
`<AI_CORE_PUBLIC_URL>/oauth2/google/callback`, ponha `AI_CORE_GOOGLE_CLIENT_ID` e `AI_CORE_GOOGLE_CLIENT_SECRET` no
`.env` e reinicie. Só entram contas já cadastradas: o e-mail verificado pelo Google precisa ser o de uma conta ativa.

### Vindo da Fase 7 (Keycloak)

O Keycloak de desenvolvimento saiu. Os nomes de usuário continuam sendo o subject da plataforma (`user:<nome>`), então
ACL e donos já gravados seguem valendo; só a identidade no Open WebUI muda.

```bash
docker compose --profile webui down
docker volume rm agentic-deploy_keycloak-data       # o Keycloak e os dados dele
# .env: tire as AI_CORE_OIDC_* e as KEYCLOAK_*; preencha POSTGRES_PASSWORD, AI_CORE_MASTER_KEY e a seção "Com interface"
docker compose up -d --build
scripts/dev-users.sh                                 # ou `ai-core users create …` com os mesmos nomes da Fase 7
```

O Open WebUI religa as contas antigas pelo e-mail (`OAUTH_MERGE_ACCOUNTS_BY_EMAIL`); se preferir começar do zero, apague
também o volume `open-webui-data`.

Com um provedor OIDC externo em vez do da plataforma, deixe `AI_CORE_IDENTITY_ENABLED` desligado e use as variáveis
`AI_CORE_OIDC_*` (o access token precisa ser JWT, com a audiência da plataforma e as claims de subject e grupos que a
003 lê); os dois juntos são recusados no boot (a plataforma confia num emissor só). A fila de execuções da API
(`AI_CORE_MAX_EXECUTIONS`, `AI_CORE_QUEUE_SIZE`, `AI_CORE_QUEUE_WAIT_MS`) vale para todos os clientes.

## CI

`.github/workflows/build.yml` roda `scripts/check-build.sh` em cada push, com deploy keys só de leitura nos segredos
`AGENTIC_APP_DEPLOY_KEY` (cadastrada no `agentic-app`) e `AI_SCOUTING_DEPLOY_KEY` (no `ai-scouting`).
