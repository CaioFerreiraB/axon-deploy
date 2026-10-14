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
| `docker-compose.yml` | o `ai-core` e o Qdrant do scouting, só na rede do compose; no perfil `webui`, o Open WebUI e um Keycloak de desenvolvimento |
| `config/assistants.yaml` | Assistants de sistema — montado em runtime, somente leitura (`interno` só para o grupo `equipe`) |
| `config/keycloak/agentic-realm.json` | realm `agentic` do Keycloak de desenvolvimento: cliente `open-webui`, audiência `ai-core`, grupos, usuários `ana` e `bia` |
| `.env.example` | perfil, chave de desenvolvimento e credenciais (copie para `.env`, fora do git) |
| `packages/incompatible-pack/` | pack incompatível de propósito, usado só pelo teste |
| `scripts/check-build.sh` | o teste da US5: compatível builda, incompatível falha, runtime sem instalador |
| `scripts/check-webui.py` | a prova da interface (008 US8): login OIDC de `ana` e `bia`, modelos de cada uma, uma mensagem pelo Open WebUI |

## Uso

O build lê o `agentic-app` e o `ai-scouting` (privados) pelo agente SSH: a sua chave precisa ter acesso aos dois.

```bash
scripts/check-build.sh                 # o teste completo
cp .env.example .env                   # e preencha
docker compose up --build -d           # ai-core em :8000 e o Qdrant
```

O pack `scouting` responde a partir do corpus indexado (`rag_first`). O corpus mora no `ai-scouting`: com um clone dele
ao lado deste repositório, a ingestão usa a CLI da própria imagem — mesma codificação na indexação e na busca:

```bash
docker compose run --rm -v ../ai-scouting/corpus:/corpus:ro ai-core ai-scouting-corpus ingest /corpus/corpus.yaml
docker compose run --rm ai-core ai-scouting-corpus status
```

Repita a ingestão quando o corpus mudar (ela reaproveita o que não mudou). O Qdrant fica no volume `qdrant-data`. Chave
do Qdrant: opcional; se usar, o mesmo valor em `QDRANT_API_KEY` e `AI_SCOUTING_QDRANT_API_KEY` no `.env`.

Trocar ou acrescentar um pack: mudar o `PACKS` (no `Dockerfile` ou com `--build-arg`) e o `config/packs.yaml`, e
rebuildar. Trocar a versão do core: `CORE_REF` (hoje `v0.5.0`: `rag_first`, harness de avaliação, fila, o verificador OIDC que aceita o JWKS do Keycloak e a timeline de status no Open WebUI).

## Open WebUI (perfil `webui`)

A interface é o Open WebUI v0.12, configurado só por ambiente (spec 008 US8; spec 002 R37–R40): login único (SSO) num
provedor OIDC, e a conexão repassa o access token de cada usuário ao `/v1` da plataforma (`system_oauth`) — cada um vê
como modelos só os Assistants que a plataforma resolve para ele. As tarefas auxiliares (título, tags, sugestões,
autocompletar, consultas de busca) ficam desligadas, e a conexão manda `x-ai-core-store: false`: o histórico é do Open
WebUI, e cada mensagem é uma execução da plataforma. Ela manda também `x-ai-core-progress: status`: o que a execução faz
aparece na timeline de status acima da resposta — a busca e os documentos achados, o portão de cobertura, a decisão do
controller, o modelo, os tokens e o tempo de cada etapa —, em vez do bloco "Pensou por N segundos". A chamada de função fica no modo legado e sem as ferramentas embutidas
do Open WebUI (`DEFAULT_MODEL_PARAMS`, `DEFAULT_MODEL_METADATA`): as capacidades vêm do Assistant, e a plataforma recusa
o campo `tools` — que o modo nativo, padrão do v0.12, mandaria em toda conversa do navegador.

Para desenvolvimento, o perfil traz um **Keycloak só de desenvolvimento** com o realm `agentic` (usuários `ana` e `bia`;
a `bia` é do grupo `equipe` e vê também o Assistant `interno`). Preencha no `.env` a seção do perfil `webui` do
`.env.example` (as `AI_CORE_OIDC_*` e os segredos de desenvolvimento) e:

```bash
docker compose --profile webui up -d --build
# http://localhost:3000 → "Continuar com Keycloak" → ana ou bia, com a senha KEYCLOAK_DEV_PASSWORD do .env
python3 scripts/check-webui.py   # a prova: listas por usuário, uma mensagem como a tela manda, uma execução (200)
docker compose --profile webui down
```

A sessão do Open WebUI dura 8 h (`OPEN_WEBUI_SESSION_EXPIRES_IN`) e a do Keycloak de desenvolvimento, 10 h: a do Open
WebUI precisa vencer antes, porque sem sessão no provedor ele não renova o token que repassa à plataforma. Se aparecer
"Model '' was not found" (lista de modelos vazia), a sessão do provedor caiu: saia do Open WebUI e entre de novo.

Os dados do Keycloak ficam no volume `keycloak-data` (o realm é importado uma vez). Apagou esse volume? Apague também o
`open-webui-data`: os usuários renascem com outro `sub`, e o Open WebUI recusa o mesmo e-mail com outra identidade.

Em produção, o provedor é o do operador: o access token precisa ser JWT, com a audiência da plataforma
(`AI_CORE_OIDC_AUDIENCE`) e as claims de subject e grupos que a 003 lê; o Keycloak deste perfil não sobe. A fila de
execuções da API (`AI_CORE_MAX_EXECUTIONS`, `AI_CORE_QUEUE_SIZE`, `AI_CORE_QUEUE_WAIT_MS`) vale para todos os clientes.

## CI

`.github/workflows/build.yml` roda `scripts/check-build.sh` em cada push, com deploy keys só de leitura nos segredos
`AGENTIC_APP_DEPLOY_KEY` (cadastrada no `agentic-app`) e `AI_SCOUTING_DEPLOY_KEY` (no `ai-scouting`).
