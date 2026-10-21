# syntax=docker/dockerfile:1.7
# Instalação da plataforma Axon (spec 002 US5; ADR-009, ADR-022; specs/002-core-pack-runtime/contracts/installation.md).
#
#   core     contratos, core e axon-generic de uma tag do axon
#   packs    core + os packs do build-arg PACKS + o modelo de embedding do scouting; `axon packs check` reprova
#            pack incompatível (falha o build)
#   runtime  o ambiente pronto, sem uv, pip nem ensurepip, como usuário sem escrita nele
#   console  a console de administração (spec 013) da mesma CORE_REF, num nginx sem privilégio (research R46)
#
# Código privado entra por montagem SSH do BuildKit (identidades `core` e `packs`): nenhuma credencial fica em camada.
#   docker buildx build --ssh core --ssh packs --target runtime -t axon:local .

ARG PYTHON_IMAGE=python:3.14-slim

FROM ${PYTHON_IMAGE} AS core
RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /usr/local/bin/uv
# Chave de host ed25519 do GitHub, a publicada em https://api.github.com/meta — fixada, sem ssh-keyscan (research R23).
RUN mkdir -p -m 0700 /root/.ssh \
 && echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" \
      > /root/.ssh/known_hosts
# ORT_DISABLE_TELEMETRY: o onnxruntime (embedding do scouting) não coleta telemetria nem tenta gravar um id de
# dispositivo — num sistema de arquivos somente leitura, isso viraria um aviso a cada processo.
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    ORT_DISABLE_TELEMETRY=1
ARG CORE_REPO=ssh://git@github.com/CaioFerreiraB/axon.git
# Tag (ou branch) do axon. O clone é raso e sem submódulos: o axon liga os packs como submódulos, e a
# identidade `core` só lê o próprio axon.
ARG CORE_REF=v0.7.0-rc2
RUN --mount=type=ssh,id=core \
    git clone --quiet --depth 1 --branch "${CORE_REF}" "${CORE_REPO}" /src/axon
RUN uv venv /opt/axon \
 && uv pip install --no-sources --python /opt/axon/bin/python \
      /src/axon/axon-ai/packages/contracts \
      /src/axon/axon-ai/packages/core \
      /src/axon/axon-ai/packages/generic

FROM core AS packs
# O packs.yaml vai na imagem: o build valida exatamente os packs e a configuração que vão rodar (research R24).
COPY config/packs.yaml /etc/axon/packs.yaml
# Requisitos separados por espaço: PyPI, URL de git (nome@git+ssh://…@ref) ou caminho em /build/packages.
# `--no-sources`: vale só o que está listado — o [tool.uv.sources] de um pack (que aponta os contratos para o git do
# axon) é ignorado, e os contratos já instalados no estágio core atendem a faixa dele.
ARG PACKS="axon-scouting@git+ssh://git@github.com/CaioFerreiraB/axon-scouting.git@da678f9ede0d75779bd0625088654a4c9bd19e0b"
RUN --mount=type=ssh,id=packs \
    --mount=type=bind,source=packages,target=/build/packages \
    uv pip install --no-sources --python /opt/axon/bin/python ${PACKS}
# O modelo denso do scouting (spec 102: revisão e sha256 fixados, verificados no download; nunca baixa em runtime). Vem
# antes do `packs check`, que carrega o pack com o `embedding_dir` do packs.yaml (research R32).
RUN /opt/axon/bin/axon-scouting-corpus model fetch /opt/axon-scouting/e5-small
RUN AXON_PACKS_FILE=/etc/axon/packs.yaml /opt/axon/bin/axon packs check

FROM ${PYTHON_IMAGE} AS runtime
# Nenhuma instalação de pack em runtime (FR-014): sem pip nem ensurepip, e o ambiente pertence a root.
RUN python -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3*/ensurepip /usr/local/bin/pip* \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin axon
COPY --from=packs /opt/axon /opt/axon
COPY --from=packs /opt/axon-scouting /opt/axon-scouting
COPY --from=packs /etc/axon/packs.yaml /etc/axon/packs.yaml
ENV PATH=/opt/axon/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    ORT_DISABLE_TELEMETRY=1 \
    AXON_HOST=0.0.0.0 \
    AXON_PACKS_FILE=/etc/axon/packs.yaml \
    AXON_ASSISTANTS_FILE=/etc/axon/assistants.yaml
USER axon
EXPOSE 8000
CMD ["axon", "serve"]

# --- A console de administração (spec 013; research R46): só é construída quando o alvo `console` é pedido ------------
FROM node:24.20.0-bookworm-slim AS console-build
# A mesma CORE_REF do core: a console fala com a API de administração daquela versão.
COPY --from=core /src/axon/axon-ai/console /src/console
WORKDIR /src/console
RUN npm ci --no-audit --no-fund && npm run build

FROM nginxinc/nginx-unprivileged:1.28.0-alpine AS console
# O envsubst da imagem renderiza o template em /etc/nginx/conf.d na subida; só as variáveis AXON_* são trocadas.
ENV NGINX_ENVSUBST_FILTER=AXON_ \
    AXON_UPSTREAM=http://axon:8000
COPY --from=console-build /src/console/dist /usr/share/nginx/html
COPY --from=console-build /src/console/deploy/nginx.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 8080
