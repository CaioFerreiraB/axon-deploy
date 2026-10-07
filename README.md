# agentic-deploy

Repositório de instalação da plataforma Agentic AI (spec 002, US5; ADR-009, ADR-022). O `Dockerfile` constrói o core a
partir de uma tag do `agentic-app`, instala os packs recebidos pelo build-arg `PACKS` e roda `ai-core packs check` no
build — pack incompatível falha o build, não a produção. O runtime não tem instalador: trocar de pack é rebuildar.

A especificação mora no `agentic-app` (`specs/002-core-pack-runtime/`, contrato `contracts/installation.md`), onde
este repositório é o submódulo `agentic-deploy/`.

## Conteúdo

| Caminho | Para quê |
|---|---|
| `Dockerfile` | estágios `core` (tag `CORE_REF` do agentic-app), `packs` (`PACKS` + `packs check`) e `runtime` |
| `config/packs.yaml` | packs habilitados — vai para a imagem, então o build valida o que roda |
| `config/assistants.yaml` | Assistants de sistema — montado em runtime, somente leitura |
| `.env.example` | perfil, chave de desenvolvimento e credenciais (copie para `.env`, fora do git) |
| `packages/incompatible-pack/` | pack incompatível de propósito, usado só pelo teste |
| `scripts/check-build.sh` | o teste da US5: compatível builda, incompatível falha, runtime sem instalador |

## Uso

O build lê o `agentic-app` e o `ai-scouting` (privados) pelo agente SSH: a sua chave precisa ter acesso aos dois.

```bash
scripts/check-build.sh                 # o teste completo
cp .env.example .env                   # e preencha
docker compose up --build              # serviço em :8000
```

Trocar ou acrescentar um pack: mudar o `PACKS` (no `Dockerfile` ou com `--build-arg`) e o `config/packs.yaml`, e
rebuildar. Trocar a versão do core: `CORE_REF`.

## CI

`.github/workflows/build.yml` roda `scripts/check-build.sh` em cada push, com deploy keys só de leitura nos segredos
`AGENTIC_APP_DEPLOY_KEY` (cadastrada no `agentic-app`) e `AI_SCOUTING_DEPLOY_KEY` (no `ai-scouting`).
