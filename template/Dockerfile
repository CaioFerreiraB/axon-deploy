# syntax=docker/dockerfile:1.7
# A imagem desta instalação (spec 002 FR-013, FR-033; ADR-041, ADR-042): os packs sobre as imagens base da plataforma.
# Nada aqui é específico de pack: trocar um pack é mudar PACKS e config/packs.yaml.
#
#   docker buildx build --ssh packs --build-arg PACKS="..." -t minha-instalacao:dev .
#
# Packs privados entram por montagem SSH do BuildKit (identidade `packs`): nenhuma credencial fica em camada.

# A versão da plataforma: a tag das imagens base (a do axon sem o "v"). Atualizar é trocar este valor.
ARG AXON_VERSION=0.7.0-rc9
ARG AXON_REGISTRY=ghcr.io/caioferreirab

FROM ${AXON_REGISTRY}/axon-build:${AXON_VERSION} AS packs
# O packs.yaml vai na imagem: o build prepara e valida exatamente os packs e a configuração que vão rodar.
COPY config/packs.yaml /etc/axon/packs.yaml
# Requisitos separados por espaço: PyPI, URL de git (nome@git+ssh://…@commit) ou caminho em /build/packages.
# `--no-sources`: vale só o que está listado — o [tool.uv.sources] de um pack é ignorado, e os contratos da imagem
# base atendem a faixa dele. Vazio: só o axon-generic, que já está na imagem base. É a fonte única dos packs: o CI e o
# compose.local.yml não o sobrescrevem.
ARG PACKS=""
RUN --mount=type=ssh,id=packs \
    --mount=type=bind,source=packages,target=/build/packages \
    if [ -n "${PACKS}" ]; then uv pip install --no-sources --python /opt/axon/bin/python ${PACKS}; fi
# Cada pack prepara os próprios dados em /opt/axon-data/<pack> (ADR-041); o check carrega os packs com eles presentes.
RUN axon packs prepare && axon packs check

FROM ${AXON_REGISTRY}/axon-runtime:${AXON_VERSION}
COPY --from=packs /opt/axon /opt/axon
COPY --from=packs /opt/axon-data /opt/axon-data
# A configuração sem segredo vai na imagem (ADR-042, item 4): mudar é um commit e uma imagem nova.
COPY config/ /etc/axon/
ENV AXON_ASSISTANTS_FILE=/etc/axon/assistants.yaml \
    AXON_IDENTITY_CLIENTS_FILE=/etc/axon/identity.yaml
