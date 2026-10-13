# syntax=docker/dockerfile:1.7
# Instalação da plataforma Agentic AI (spec 002 US5; ADR-009, ADR-022; specs/002-core-pack-runtime/contracts/installation.md).
#
#   core     contratos, core e ai-generic de uma tag do agentic-app
#   packs    core + os packs do build-arg PACKS + o modelo de embedding do scouting; `ai-core packs check` reprova
#            pack incompatível (falha o build)
#   runtime  o ambiente pronto, sem uv, pip nem ensurepip, como usuário sem escrita nele
#
# Código privado entra por montagem SSH do BuildKit (identidades `core` e `packs`): nenhuma credencial fica em camada.
#   docker buildx build --ssh core --ssh packs --target runtime -t agentic-deploy .

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
ARG CORE_REPO=ssh://git@github.com/CaioFerreiraB/agentic-app.git
# Tag (ou branch) do agentic-app. O clone é raso e sem submódulos: o agentic-app liga os packs como submódulos, e a
# identidade `core` só lê o próprio agentic-app.
ARG CORE_REF=v0.4.1
RUN --mount=type=ssh,id=core \
    git clone --quiet --depth 1 --branch "${CORE_REF}" "${CORE_REPO}" /src/agentic-app
RUN uv venv /opt/ai-core \
 && uv pip install --no-sources --python /opt/ai-core/bin/python \
      /src/agentic-app/ai-core/packages/contracts \
      /src/agentic-app/ai-core/packages/core \
      /src/agentic-app/ai-core/packages/generic

FROM core AS packs
# O packs.yaml vai na imagem: o build valida exatamente os packs e a configuração que vão rodar (research R24).
COPY config/packs.yaml /etc/ai-core/packs.yaml
# Requisitos separados por espaço: PyPI, URL de git (nome@git+ssh://…@ref) ou caminho em /build/packages.
# `--no-sources`: vale só o que está listado — o [tool.uv.sources] de um pack (que aponta os contratos para o git do
# agentic-app) é ignorado, e os contratos já instalados no estágio core atendem a faixa dele.
ARG PACKS="ai-scouting@git+ssh://git@github.com/CaioFerreiraB/ai-scouting.git@24cb157590dbc81c9b6778de0b868fcc8064c36b"
RUN --mount=type=ssh,id=packs \
    --mount=type=bind,source=packages,target=/build/packages \
    uv pip install --no-sources --python /opt/ai-core/bin/python ${PACKS}
# O modelo denso do scouting (spec 102: revisão e sha256 fixados, verificados no download; nunca baixa em runtime). Vem
# antes do `packs check`, que carrega o pack com o `embedding_dir` do packs.yaml (research R32).
RUN /opt/ai-core/bin/ai-scouting-corpus model fetch /opt/ai-scouting/e5-small
RUN AI_CORE_PACKS_FILE=/etc/ai-core/packs.yaml /opt/ai-core/bin/ai-core packs check

FROM ${PYTHON_IMAGE} AS runtime
# Nenhuma instalação de pack em runtime (FR-014): sem pip nem ensurepip, e o ambiente pertence a root.
RUN python -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3*/ensurepip /usr/local/bin/pip* \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin ai-core
COPY --from=packs /opt/ai-core /opt/ai-core
COPY --from=packs /opt/ai-scouting /opt/ai-scouting
COPY --from=packs /etc/ai-core/packs.yaml /etc/ai-core/packs.yaml
ENV PATH=/opt/ai-core/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    ORT_DISABLE_TELEMETRY=1 \
    AI_CORE_HOST=0.0.0.0 \
    AI_CORE_PACKS_FILE=/etc/ai-core/packs.yaml \
    AI_CORE_ASSISTANTS_FILE=/etc/ai-core/assistants.yaml
USER ai-core
EXPOSE 8000
CMD ["ai-core", "serve"]
