# syntax=docker/dockerfile:1.7
# Imagens base da plataforma Axon (spec 002 FR-032; ADR-042; specs/002-core-pack-runtime/contracts/installation.md).
# Uma tag do axon vira três imagens com a mesma versão; nenhuma traz pack além do axon-generic, endereço ou segredo.
#
#   build    contratos, core e axon-generic em /opt/axon, com uv, git e cliente SSH: o ponto de partida do estágio que
#            instala os packs de uma instalação (template/Dockerfile)
#   runtime  o mesmo ambiente sem uv, pip nem ensurepip, como usuário sem escrita nele; roda sozinha, só com o generic
#   console  a console de administração (spec 013) da mesma tag, num nginx sem privilégio
#
# O axon é privado: o clone usa a identidade SSH `core` do BuildKit, e o código entra nos outros estágios só por
# montagem — nenhum fonte nem credencial fica em camada.
#   docker buildx build --ssh core --build-arg CORE_REF=v0.7.0-rc6 --target runtime -t axon-runtime:0.7.0-rc6 images

ARG PYTHON_IMAGE=python:3.14-slim

FROM ${PYTHON_IMAGE} AS tools
RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /usr/local/bin/uv
# Chave de host ed25519 do GitHub, a publicada em https://api.github.com/meta — fixada, sem ssh-keyscan (research R23).
# Fica na imagem de build: as instalações instalam packs privados por git+ssh com ela.
RUN mkdir -p -m 0700 /root/.ssh \
 && echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" \
      > /root/.ssh/known_hosts

FROM tools AS source
ARG CORE_REPO=ssh://git@github.com/CaioFerreiraB/axon.git
# Tag do axon (o CI só publica tags; localmente, uma branch serve). Clone raso e sem submódulos: o axon liga os packs
# de domínio como submódulos, e a identidade `core` só lê o próprio axon.
ARG CORE_REF
RUN test -n "${CORE_REF}" || { echo "defina --build-arg CORE_REF=<tag do axon>" >&2; exit 1; }
RUN --mount=type=ssh,id=core \
    git clone --quiet --depth 1 --branch "${CORE_REF}" "${CORE_REPO}" /src/axon

FROM tools AS build
ARG CORE_REF
LABEL org.opencontainers.image.source=https://github.com/CaioFerreiraB/axon-deploy \
      org.opencontainers.image.description="Axon: imagem de build (contratos, core e axon-generic, com uv)" \
      org.opencontainers.image.version=${CORE_REF}
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    PATH=/opt/axon/bin:$PATH \
    AXON_PACKS_FILE=/etc/axon/packs.yaml \
    AXON_PACKS_DATA_DIR=/opt/axon-data
RUN --mount=type=bind,from=source,source=/src/axon/axon-ai/packages,target=/src/packages \
    uv venv /opt/axon \
 && uv pip install --no-sources --python /opt/axon/bin/python \
      /src/packages/contracts /src/packages/core /src/packages/generic
# O packs.yaml de base habilita só o generic; a instalação o troca pelo dela. A raiz de dados existe mesmo sem pack
# com dados, para o estágio de runtime da instalação sempre ter o que copiar (ADR-041).
COPY packs.yaml /etc/axon/packs.yaml
RUN mkdir -p /opt/axon-data \
 && axon packs prepare \
 && axon packs check

FROM ${PYTHON_IMAGE} AS runtime
ARG CORE_REF
LABEL org.opencontainers.image.source=https://github.com/CaioFerreiraB/axon-deploy \
      org.opencontainers.image.description="Axon: imagem de runtime (sem instalador; axon serve)" \
      org.opencontainers.image.version=${CORE_REF}
# Nenhuma instalação de pack em runtime (FR-014): sem pip nem ensurepip, e o ambiente pertence a root.
RUN python -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3*/ensurepip /usr/local/bin/pip* \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin axon
COPY --from=build /opt/axon /opt/axon
COPY --from=build /opt/axon-data /opt/axon-data
COPY --from=build /etc/axon/packs.yaml /etc/axon/packs.yaml
ENV PATH=/opt/axon/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    AXON_HOST=0.0.0.0 \
    AXON_PACKS_FILE=/etc/axon/packs.yaml \
    AXON_PACKS_DATA_DIR=/opt/axon-data
USER axon
EXPOSE 8000
CMD ["axon", "serve"]

FROM node:24.20.0-bookworm-slim AS console-build
# A mesma tag do core: a console fala com a API de administração daquela versão.
COPY --from=source /src/axon/axon-ai/console /src/console
WORKDIR /src/console
RUN npm ci --no-audit --no-fund && npm run build

FROM nginxinc/nginx-unprivileged:1.28.0-alpine AS console
ARG CORE_REF
LABEL org.opencontainers.image.source=https://github.com/CaioFerreiraB/axon-deploy \
      org.opencontainers.image.description="Axon: console de administração (nginx sem privilégio)" \
      org.opencontainers.image.version=${CORE_REF}
# O envsubst da imagem renderiza o template em /etc/nginx/conf.d na subida; só as variáveis AXON_* são trocadas.
ENV NGINX_ENVSUBST_FILTER=AXON_ \
    AXON_UPSTREAM=http://axon:8000
COPY --from=console-build /src/console/dist /usr/share/nginx/html
COPY --from=console-build /src/console/deploy/nginx.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 8080
