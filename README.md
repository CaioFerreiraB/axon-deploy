# axon-deploy

A referência de instalação da plataforma Axon (spec 002 US5, FR-032, FR-033; ADR-041, ADR-042). Este repositório
**não é uma instalação**. Ele publica:

- as **imagens base** de cada versão do core — `axon-build`, `axon-runtime` e `axon-console`, no GHCR;
- o **modelo de instalação** (`template/`), que cada instalação copia para um repositório próprio e privado.

Nenhum pack além do `axon-generic`, nenhum endereço e nenhum segredo moram aqui. A especificação está no `axon`
(`specs/002-core-pack-runtime/`, contrato `contracts/installation.md`), onde este repositório é o submódulo
`axon-deploy/`.

## Três camadas

| Camada | Onde | O que decide |
|---|---|---|
| Plataforma | este repositório | as imagens base por versão do core e o modelo de instalação |
| Pack | o repositório de cada pack | o que ele precisa em runtime, preparado no build pelo hook `prepare` (ADR-041); os serviços de que depende, documentados |
| Instalação | um repositório privado por instalação, criado de `template/` | a versão da plataforma, os packs, a configuração, os serviços dos packs, os domínios |

## Conteúdo

| Caminho | Para quê |
|---|---|
| `images/Dockerfile` | alvos `build`, `runtime` e `console`, de uma tag do `axon` (`CORE_REF`) |
| `images/packs.yaml` | o `packs.yaml` das imagens base: só o `generic` |
| `template/` | o modelo de instalação: `Dockerfile` sem nada de pack, `config/`, `compose.yml`, `compose.local.yml`, `.env.example`, workflow de release e o README da instalação |
| `packages/incompatible-pack/` | pack incompatível de propósito, usado só pela prova |
| `scripts/check-build.sh` | a prova: imagens base, o modelo sobre elas, o incompatível recusado, nada instalado em runtime |
| `.github/workflows/build.yml` | a prova a cada PR e push (nada é publicado) |
| `.github/workflows/images.yml` | publica as imagens base de uma tag do `axon` (manual) |

## As imagens base

| Imagem | Conteúdo |
|---|---|
| `axon-build` | contratos, core e `axon-generic` em `/opt/axon`, com `uv`, git, cliente SSH e a chave de host do GitHub; `AXON_PACKS_DATA_DIR=/opt/axon-data` |
| `axon-runtime` | o mesmo ambiente sem `uv`, `pip` nem `ensurepip`; usuário `axon` (uid 10001) sem escrita em `/opt/axon`, `/opt/axon-data` e `/etc/axon`; `axon serve`. Roda sozinha, só com o `generic` |
| `axon-console` | a console de administração da mesma tag, no nginx sem privilégio |

A tag de cada imagem é a do `axon` sem o `v` (`v0.7.0-rc10` → `0.7.0-rc10`). É imutável: o workflow recusa publicar
uma tag que já existe, e não há `latest`. As imagens ficam em `ghcr.io/caioferreirab/`, privadas enquanto o `axon` for.

Para publicar uma versão nova do core, depois da tag no `axon`:

```bash
gh workflow run images.yml -f core_ref=v0.7.0-rc10
```

O workflow roda a prova sobre a mesma tag antes de publicar.

## Prova local

```bash
scripts/check-build.sh                       # a versão do template/Dockerfile
CORE_REF=minha-branch scripts/check-build.sh  # outra tag ou branch do axon
```

O build lê o `axon` (privado) pela identidade SSH `core`: o agente SSH, ou `SSH_CORE=<arquivo de chave>`. As imagens
ficam só no Docker local, com o prefixo `axon-check/`.

## Uma instalação nova

Crie um repositório privado, copie `template/` para a raiz dele e siga o `README.md` que vem junto: versão, packs,
configuração, release pelo CI e deploy no Portainer CE.

## CI

Os dois workflows leem o `axon` pela deploy key só de leitura do segredo `AGENTIC_APP_DEPLOY_KEY`. O nome é de antes do
ADR-037. O `images.yml` publica com o `GITHUB_TOKEN` (`packages: write`). A prova não lê nenhum pack privado.

## Licença

[MIT](LICENSE).
