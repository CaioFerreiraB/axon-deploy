# Instalação da plataforma Axon

Este repositório é uma **instalação**: escolhe a versão da plataforma, os packs, a configuração e os serviços de que
os packs dependem. Foi criado a partir do modelo em `template/` do
[`axon-deploy`](https://github.com/CaioFerreiraB/axon-deploy), que publica as imagens base (ADR-042 do `axon`).

| Arquivo | O que é |
|---|---|
| `Dockerfile` | os packs sobre `axon-build`, depois `axon packs prepare` e `axon packs check`; o runtime sobre `axon-runtime` |
| `config/` | `packs.yaml`, `assistants.yaml`, `identity.yaml` e o logotipo opcional: vão para `/etc/axon` na imagem |
| `compose.yml` | a stack em execução: só imagens, tags fixadas, sem porta publicada, proxy numa rede externa |
| `compose.local.yml` | build local e portas, para rodar na máquina do operador |
| `.env.example` | as variáveis da stack (segredos só aqui, nunca em arquivo) |
| `.github/workflows/release.yml` | constrói e publica a imagem desta instalação a cada push na branch principal ou tag |

## Escolher a plataforma e os packs

- **Versão**: `ARG AXON_VERSION` no `Dockerfile` (a tag das imagens base; a do `axon` sem o `v`) e a tag da
  `axon-console` no `compose.yml` — as duas sempre iguais.
- **Packs**: o `ARG PACKS` do `Dockerfile` — requisitos separados por espaço, do PyPI, de um repositório git
  (`nome@git+ssh://git@github.com/dono/repo.git@<commit>`) ou de `packages/` (`/build/packages/x`) — e a entrada de cada
  um em `config/packs.yaml`. O CI e o build local usam esse mesmo valor. Os dados de cada pack (um modelo, um índice) são preparados no
  build pelo próprio pack, em `/opt/axon-data/<pack>`.
- **Serviços de packs**: se um pack precisa de um serviço (um banco de vetores, por exemplo), o README do pack diz qual;
  acrescente-o ao `compose.yml`, e os segredos dele à lista `environment` do serviço `axon`.

## Rodar na máquina

```bash
cp .env.example .env    # preencha, e acrescente COMPOSE_FILE=compose.yml:compose.local.yml
docker compose up --build
docker compose exec axon axon users create admin --email admin@exemplo.org --group admin
```

A plataforma fica em `http://localhost:8000`, a console em `http://localhost:8080` e o chat em `http://localhost:3000`
(com `AXON_PUBLIC_URL=http://localhost:8080` e `AXON_CHAT_URL=http://localhost:3000` no `.env`).

## Publicar e implantar (Portainer CE)

1. **Release**: cada push na branch principal publica `ghcr.io/<dono>/<repositório>:sha-<commit>` (e `:<versão>` numa
   tag `v<versão>`). O repositório precisa de leitura nos pacotes `axon-build` e `axon-runtime` do GHCR ("Manage
   Actions access" de cada pacote) e, com packs privados, do segredo `PACKS_DEPLOY_KEY` (deploy key só de leitura).
2. **Tag no compose**: troque `image:` do serviço `axon` pela tag publicada e faça commit. Atualizar é sempre isso.
3. **Stack**: no Portainer, *Stacks → Add stack → Repository*, apontando para este repositório e o `compose.yml`; as
   variáveis do `.env.example` nas variáveis da stack; o registry `ghcr.io` cadastrado com um token só de leitura de
   pacotes. Atualização pelo *redeploy* (ou pelo *polling* do Git).
4. **Proxy**: crie a rede (`docker network create proxy`) e ligue o proxy reverso a ela. Ele encaminha o domínio da
   console (o `AXON_PUBLIC_URL`) para `axon-console:8080`, o do chat (`AXON_CHAT_URL`) para `axon-chat:8080` e, sem
   console, o da API para `axon-api:8000`. Com Caddy:

   ```caddy
   axon.exemplo.org {
       reverse_proxy axon-console:8080
   }
   chat.exemplo.org {
       reverse_proxy axon-chat:8080
   }
   ```

5. **Primeiro administrador**: no console do contêiner `axon` (Portainer → *Containers → axon → Console*),
   `axon users create <nome> --email <e-mail> --group admin`. A senha temporária aparece uma vez, e a troca é exigida no
   primeiro login.

Mudar a configuração é um commit e uma imagem nova. No dia a dia, modelos, servidores MCP e quem usa cada Assistant
mudam pela console, nas seções liberadas em `overrides`.
