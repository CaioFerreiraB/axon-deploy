#!/usr/bin/env bash
# Contas de desenvolvimento para a prova do Open WebUI (spec 002 R39, R49): o grupo `equipe`, a `ana` (sem grupo) e a
# `bia` (do grupo `equipe`), todas com a senha DEV_USERS_PASSWORD do .env. Roda contra o banco da instalação, com a
# identidade ligada; repetir é inofensivo (quem já existe é mantido). Rode da raiz do axon-deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

password=$(sed -n 's/^DEV_USERS_PASSWORD=//p' .env | tail -1)
[[ -n "$password" ]] || { echo "defina DEV_USERS_PASSWORD no .env" >&2; exit 1; }

axon() { docker compose run --rm -T axon axon "$@"; }

axon groups create equipe || true
printf '%s\n' "$password" | axon users create ana --email ana@axon.local --name "Ana" --password-stdin || true
printf '%s\n' "$password" \
  | axon users create bia --email bia@axon.local --name "Bia" --group equipe --password-stdin || true
axon users list
