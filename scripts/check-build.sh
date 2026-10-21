#!/usr/bin/env bash
# Independent Test da US5 (spec 002; research R27; contracts/installation.md): pack compatível builda; pack
# incompatível falha no `packs check`; o runtime não instala nada.
#
#   SSH_CORE, SSH_PACKS  arquivo de chave de cada identidade SSH do build (default: o agente SSH)
#   CORE_REF             tag ou branch do axon (default: a do Dockerfile)
#   IMAGE                nome da imagem de teste (default: axon:check)
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-axon:check}"
build_args=(--ssh "core${SSH_CORE:+=$SSH_CORE}" --ssh "packs${SSH_PACKS:+=$SSH_PACKS}")
[[ -n "${CORE_REF:-}" ]] && build_args+=(--build-arg "CORE_REF=$CORE_REF")
default_packs=$(sed -n 's/^ARG PACKS="\(.*\)"$/\1/p' Dockerfile)

step() { printf '\n== %s\n' "$*"; }
# Os comandos `axon` sobem a configuração inteira: o assistants.yaml é montado, como na execução real.
axon() { docker run --rm -v "$PWD/config/assistants.yaml:/etc/axon/assistants.yaml:ro" "$IMAGE" axon "$@"; }
fail() { printf '\nFALHOU: %s\n' "$*" >&2; exit 1; }

step "1. build com os packs default (US5 cen. 1)"
docker buildx build "${build_args[@]}" --target runtime --load -t "$IMAGE" .

step "2. os packs estão habilitados na imagem"
list=$(axon packs list)
echo "$list"
grep -Eq '^generic .* enabled' <<<"$list" || fail "generic não está enabled"
grep -Eq '^scouting .* enabled' <<<"$list" || fail "scouting não está enabled"

step "2b. o modelo de embedding do scouting e a CLI do corpus estão na imagem"
docker run --rm "$IMAGE" test -f /opt/axon-scouting/e5-small/model.onnx -a -f /opt/axon-scouting/e5-small/tokenizer.json \
  || fail "o modelo do scouting não está em /opt/axon-scouting/e5-small"
docker run --rm "$IMAGE" axon-scouting-corpus --help >/dev/null || fail "axon-scouting-corpus não roda na imagem"
echo "modelo em /opt/axon-scouting/e5-small; axon-scouting-corpus disponível"

step "3. os Assistants da instalação validam"
axon assistants validate || fail "assistants validate reprovou config/assistants.yaml"

step "3b. variáveis com o nome antigo não sobem (US7 cen. 6; ADR-037)"
if output=$(docker run --rm -e AI_CORE_PROFILE=memory "$IMAGE" axon packs list 2>&1); then
  fail "a imagem aceitou AI_CORE_PROFILE"
fi
grep -q 'AI_CORE_PROFILE → AXON_PROFILE' <<<"$output" || { echo "$output"; fail "a recusa não nomeou AXON_PROFILE"; }
echo "recusada: AI_CORE_PROFILE → AXON_PROFILE"

step "4. nenhuma instalação em runtime (US5 cen. 3)"
if docker run --rm "$IMAGE" sh -c 'command -v uv'; then fail "uv presente no runtime"; fi
if docker run --rm "$IMAGE" sh -c 'command -v pip || python -m pip --version'; then fail "pip presente no runtime"; fi
if docker run --rm "$IMAGE" python -m ensurepip --version 2>/dev/null; then fail "ensurepip presente no runtime"; fi
if docker run --rm "$IMAGE" sh -c 'touch /opt/axon/.escrita'; then fail "o usuário do processo escreve em /opt/axon"; fi
echo "sem uv, pip e ensurepip; /opt/axon somente leitura para o processo"

step "5. pack incompatível falha no packs check (US5 cen. 2)"
if output=$(docker buildx build "${build_args[@]}" --target packs --progress plain \
    --build-arg "PACKS=$default_packs /build/packages/incompatible-pack" . 2>&1); then
  fail "o build com o pack incompatível passou"
fi
grep -q 'axon packs check' <<<"$output" || { tail -30 <<<"$output"; fail "o build falhou antes do packs check"; }
grep -Eq 'incompatible .* error' <<<"$output" || { tail -30 <<<"$output"; fail "o packs check não nomeou o pack incompatível"; }
if grep -Eq 'scouting .* error' <<<"$output"; then fail "o scouting apareceu em erro"; fi
grep -E 'incompatible .* error' <<<"$output" | tail -1

printf '\nOK: a instalação builda com packs compatíveis, recusa o incompatível e não instala nada em runtime.\n'
