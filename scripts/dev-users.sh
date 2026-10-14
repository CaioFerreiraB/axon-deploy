#!/usr/bin/env bash
# Contas de desenvolvimento para a prova do Open WebUI (spec 002 R39, R49): o grupo `equipe`, a `ana` (sem grupo) e a
# `bia` (do grupo `equipe`), todas com a senha DEV_USERS_PASSWORD do .env. Roda contra o banco da instalação, com a
# identidade ligada; repetir é inofensivo (quem já existe é mantido). Rode da raiz do agentic-deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

password=$(sed -n 's/^DEV_USERS_PASSWORD=//p' .env | tail -1)
[[ -n "$password" ]] || { echo "defina DEV_USERS_PASSWORD no .env" >&2; exit 1; }

ai_core() { docker compose run --rm -T ai-core ai-core "$@"; }

ai_core groups create equipe || true
printf '%s\n' "$password" | ai_core users create ana --email ana@agentic.local --name "Ana" --password-stdin || true
printf '%s\n' "$password" \
  | ai_core users create bia --email bia@agentic.local --name "Bia" --group equipe --password-stdin || true
ai_core users list
