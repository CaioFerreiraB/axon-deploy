#!/usr/bin/env bash
# Prova da referência (spec 002 US5, FR-032, FR-033; ADR-041, ADR-042; contracts/installation.md): as imagens base de
# uma tag do axon e, sobre elas, o modelo de instalação. Pack compatível builda; pack incompatível falha no
# `packs check`; o runtime não instala nada; nada de pack além do generic.
#
#   SSH_CORE  arquivo de chave da identidade `core` do build (default: o agente SSH)
#   CORE_REF  tag (ou branch) do axon (default: a do AXON_VERSION de template/Dockerfile, com "v")
#   REGISTRY  prefixo das imagens base (default: axon-check, só local); VERSION, a tag delas (default: CORE_REF sem "v")
set -euo pipefail
cd "$(dirname "$0")/.."

template_version=$(sed -n 's/^ARG AXON_VERSION=\(.*\)$/\1/p' template/Dockerfile)
CORE_REF="${CORE_REF:-v$template_version}"
REGISTRY="${REGISTRY:-axon-check}"
VERSION="${VERSION:-${CORE_REF#v}}"
INSTALLATION="axon-instalacao:check"
ssh_core=(--ssh "core${SSH_CORE:+=$SSH_CORE}")
base_args=(--build-arg "CORE_REF=$CORE_REF")
template_args=(--build-arg "AXON_REGISTRY=$REGISTRY" --build-arg "AXON_VERSION=$VERSION")

step() { printf '\n== %s\n' "$*"; }
fail() { printf '\nFALHOU: %s\n' "$*" >&2; exit 1; }
in_image() { local image=$1; shift; docker run --rm "$image" "$@"; }

# O contexto do modelo tem só os arquivos que o git rastreia (com as edições locais): um arquivo que ficou fora do
# commit falha aqui como falharia no CI e na instalação que copia o modelo.
context=$(mktemp -d)
trap 'rm -rf "$context"' EXIT
git ls-files -z template | xargs -0 cp --parents -t "$context"
model="$context/template"

step "1. imagens base de $CORE_REF ($REGISTRY/axon-{build,runtime,console}:$VERSION)"
for target in build runtime console; do
  docker buildx build "${ssh_core[@]}" "${base_args[@]}" --target "$target" --load \
    -t "$REGISTRY/axon-$target:$VERSION" images
done

step "2. a imagem de runtime base roda sozinha, só com o generic (US5 cen. 4)"
base="$REGISTRY/axon-runtime:$VERSION"
list=$(in_image "$base" axon packs list)
echo "$list"
grep -Eq '^generic .* enabled' <<<"$list" || fail "generic não está enabled na imagem base"
[[ $(grep -c . <<<"$list") -eq 1 ]] || fail "a imagem base tem pack além do generic"
in_image "$base" test -d /opt/axon-data/generic || fail "a raiz de dados da imagem base não foi preparada"

step "3. o modelo de instalação, sem mudança, sobre as imagens base (US5 cen. 1, 5)"
docker buildx build "${template_args[@]}" --load -t "$INSTALLATION" "$model"
list=$(in_image "$INSTALLATION" axon packs list)
echo "$list"
grep -Eq '^generic .* enabled' <<<"$list" || fail "generic não está enabled na instalação"
for file in packs.yaml assistants.yaml identity.yaml; do
  in_image "$INSTALLATION" test -f "/etc/axon/$file" || fail "/etc/axon/$file não está na imagem"
done
in_image "$INSTALLATION" test -d /opt/axon-data/generic || fail "a raiz de dados não veio do estágio de build"
in_image "$INSTALLATION" axon assistants validate || fail "assistants validate reprovou template/config/assistants.yaml"

step "3b. variáveis com o nome antigo não sobem (US7 cen. 6; ADR-037)"
if output=$(docker run --rm -e AI_CORE_PROFILE=memory "$INSTALLATION" axon packs list 2>&1); then
  fail "a imagem aceitou AI_CORE_PROFILE"
fi
grep -q 'AI_CORE_PROFILE → AXON_PROFILE' <<<"$output" || { echo "$output"; fail "a recusa não nomeou AXON_PROFILE"; }
echo "recusada: AI_CORE_PROFILE → AXON_PROFILE"

step "4. nenhuma instalação em runtime (US5 cen. 3)"
for image in "$base" "$INSTALLATION"; do
  if in_image "$image" sh -c 'command -v uv'; then fail "uv presente em $image"; fi
  if in_image "$image" sh -c 'command -v pip || python -m pip --version'; then fail "pip presente em $image"; fi
  if in_image "$image" python -m ensurepip --version 2>/dev/null; then fail "ensurepip presente em $image"; fi
  for dir in /opt/axon /opt/axon-data /etc/axon; do
    if in_image "$image" sh -c "touch $dir/.escrita" 2>/dev/null; then fail "o processo escreve em $dir ($image)"; fi
  done
done
echo "sem uv, pip e ensurepip; /opt/axon, /opt/axon-data e /etc/axon somente leitura para o processo"

step "5. pack incompatível falha no packs check (US5 cen. 2)"
incompatible="$context/incompatible"
cp -r "$model" "$incompatible"
cp -r packages/incompatible-pack "$incompatible/packages/"
if output=$(docker buildx build "${template_args[@]}" --progress plain \
    --build-arg "PACKS=/build/packages/incompatible-pack" "$incompatible" 2>&1); then
  fail "o build com o pack incompatível passou"
fi
grep -q 'axon packs check' <<<"$output" || { tail -30 <<<"$output"; fail "o build falhou antes do packs check"; }
grep -Eq 'incompatible .* error' <<<"$output" || { tail -30 <<<"$output"; fail "o packs check não nomeou o pack incompatível"; }
grep -E 'incompatible .* error' <<<"$output" | tail -1

step "6. a console da mesma tag e o compose do modelo"
in_image "$REGISTRY/axon-console:$VERSION" test -f /usr/share/nginx/html/index.html || fail "a SPA não está na console"
env_file="$context/check.env"
printf '%s\n' AXON_PROXY_NETWORK=proxy POSTGRES_PASSWORD=x AXON_MASTER_KEY=x AXON_PUBLIC_URL=https://axon.test \
  AXON_CHAT_URL=https://chat.test WEBUI_SECRET_KEY=x COMPOSE_PROFILES=webui,console > "$env_file"
docker compose --env-file "$env_file" -f "$model/compose.yml" config --quiet || fail "template/compose.yml inválido"
docker compose --env-file "$env_file" -f "$model/compose.yml" -f "$model/compose.local.yml" config --quiet \
  || fail "template/compose.local.yml inválido"
if grep -nE '^\s+(ports|build):' "$model/compose.yml"; then fail "template/compose.yml publica porta ou tem build"; fi
echo "console com a SPA; compose do modelo válido, só com imagens e sem porta publicada"

printf '\nOK: imagens base %s, modelo de instalação sobre elas, incompatível recusado, nada instalado em runtime.\n' "$VERSION"
