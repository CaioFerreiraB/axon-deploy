#!/usr/bin/env python3
"""Prova da interface (spec 002 R40; spec 008 US8 cen. 2–5): Open WebUI + Keycloak de desenvolvimento + plataforma.

Com o perfil webui de pé (`docker compose --profile webui up -d`), entra no Open WebUI como `ana` e como `bia` pelo
fluxo OIDC de verdade (o formulário do Keycloak), lê a lista de modelos de cada uma e manda uma mensagem pelo próprio
Open WebUI, que chega à plataforma pela conexão `system_oauth`. Confere:

  1. a `bia` (grupo equipe) vê o Assistant `interno`; a `ana`, não — e as duas veem os públicos (US8 cen. 1–2);
  2. a mensagem volta respondida pela plataforma (US8 cen. 3);
  3. o log de acesso do ai-core mostra exatamente um POST /v1/chat/completions — nenhuma tarefa auxiliar (cen. 4);
  4. a resposta não traz id de conversa: a conexão manda x-ai-core-store: false (cen. 5).

Só biblioteca padrão; lê as senhas de desenvolvimento do .env sem exibi-las. Rode da raiz do agentic-deploy.
"""

from __future__ import annotations

import html
import json
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar, DefaultCookiePolicy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORM = re.compile(r'<form[^>]*\bid="kc-form-login"[^>]*>|<form[^>]*\baction="[^"]*login-actions[^"]*"[^>]*>', re.S)
ACTION = re.compile(r'\baction="([^"]+)"')
MESSAGE = "Responda só com a palavra: pronto."


def env() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            name, _, value = line.partition("=")
            values[name.strip()] = value.strip()
    return values


CONFIG = env()
WEBUI = f"http://localhost:{CONFIG.get('OPEN_WEBUI_HOST_PORT', '3000')}"


def fail(message: str) -> None:
    print(f"\nFALHOU: {message}", file=sys.stderr)
    sys.exit(1)


class Session:
    """Um usuário logado no Open WebUI: os cookies do navegador (`token`, `oauth_session_id`) e o token da API."""

    def __init__(self, user: str) -> None:
        self.user = user
        # O Keycloak marca os cookies de sessão como `Secure`; os navegadores os mandam para http://localhost (contexto
        # seguro), mas o cookiejar do Python só por https — sem isto, o login volta 400 ("cookie não encontrado").
        self.jar = CookieJar(policy=DefaultCookiePolicy(secure_protocols=("https", "wss", "http")))
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        page = self.opener.open(f"{WEBUI}/oauth/oidc/login", timeout=30).read().decode("utf-8")
        form = FORM.search(page)
        action = ACTION.search(form.group(0)) if form else None
        if action is None:
            fail(f"{user}: o formulário de login do Keycloak não apareceu")
        fields = {"username": user, "password": CONFIG["KEYCLOAK_DEV_PASSWORD"], "credentialId": ""}
        data = urllib.parse.urlencode(fields).encode()
        self.opener.open(html.unescape(action.group(1)), data=data, timeout=30).read()
        cookies = {cookie.name: cookie.value for cookie in self.jar}
        if "token" not in cookies:
            fail(f"{user}: o Open WebUI não abriu sessão depois do login (cookies: {sorted(cookies)})")
        self.token = cookies["token"]

    def get(self, path: str) -> object:
        request = urllib.request.Request(f"{WEBUI}{path}", headers={"Authorization": f"Bearer {self.token}"})
        return json.loads(self.opener.open(request, timeout=60).read())

    def post(self, path: str, body: dict[str, object]) -> object:
        request = urllib.request.Request(
            f"{WEBUI}{path}",
            data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        return json.loads(self.opener.open(request, timeout=120).read())

    def models(self) -> set[str]:
        payload = self.get("/api/models")
        data = payload["data"] if isinstance(payload, dict) else payload
        return {model["id"] for model in data}


def chat_requests_since(since: str) -> list[str]:
    logs = subprocess.run(
        ["docker", "compose", "logs", "--no-color", "--since", since, "ai-core"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in logs.splitlines() if "/v1/chat/completions" in line]


def main() -> None:
    print("== 1. login OIDC e lista de modelos por usuário")
    ana, bia = Session("ana"), Session("bia")
    modelos_ana, modelos_bia = ana.models(), bia.models()
    print(f"ana: {sorted(modelos_ana)}\nbia: {sorted(modelos_bia)}")
    if "interno" not in modelos_bia:
        fail("a bia (grupo equipe) não vê o Assistant interno")
    if "interno" in modelos_ana:
        fail("a ana vê o Assistant interno, que é só do grupo equipe")
    if not {"geral", "scouting"} <= modelos_ana:
        fail("a ana não vê os Assistants públicos")

    print("\n== 2. uma mensagem pelo Open WebUI chega à plataforma")
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 1))
    body = {"model": "interno", "messages": [{"role": "user", "content": MESSAGE}], "stream": False}
    resposta = bia.post("/api/chat/completions", body)
    texto = resposta["choices"][0]["message"]["content"]  # type: ignore[index]
    print(f"resposta: {texto!r}")
    if not texto.strip():
        fail("resposta vazia")

    print("\n== 3. uma execução por mensagem (nenhuma tarefa auxiliar)")
    time.sleep(3)  # tarefas em segundo plano do Open WebUI, se houvesse, já teriam chamado
    pedidos = chat_requests_since(since)
    for linha in pedidos:
        print(linha)
    if len(pedidos) != 1:
        fail(f"esperado 1 POST /v1/chat/completions no ai-core, vieram {len(pedidos)}")

    print("\n== 4. pedido efêmero: nenhuma conversa na resposta")
    extra = resposta.get("x_ai_core") if isinstance(resposta, dict) else None
    if extra is not None and extra.get("conversation_id"):
        fail(f"a plataforma gravou a conversa {extra['conversation_id']} (x-ai-core-store não chegou?)")
    print("sem conversation_id" if extra is not None else "o Open WebUI não repassa o campo extra; nada a conferir aqui")

    print("\nOK: cada usuário vê só os próprios Assistants, e uma mensagem do Open WebUI é uma execução da plataforma.")


if __name__ == "__main__":
    main()
