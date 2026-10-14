#!/usr/bin/env python3
"""Prova da interface (spec 002 R40, R49; spec 008 US8 cen. 2–5): Open WebUI + o provedor de identidade da plataforma.

Com o perfil webui de pé e as contas de desenvolvimento criadas (`scripts/dev-users.sh`), entra no Open WebUI como
`ana` e como `bia` pelo fluxo OIDC de verdade — o formulário de login da própria plataforma (spec 012) —, lê a lista
de modelos de cada uma e manda uma mensagem pelo próprio Open WebUI, que chega à plataforma pela conexão
`system_oauth` com o token que a plataforma emitiu. Confere:

  1. a `bia` (grupo equipe) vê o Assistant `interno`; a `ana`, não — e as duas veem os públicos (US8 cen. 1–2);
  2. a mensagem, montada como a tela de chat a monta, volta respondida pela plataforma (US8 cen. 3);
  3. o log de acesso do ai-core mostra exatamente um POST /v1/chat/completions — nenhuma tarefa auxiliar (cen. 4);
  4. esse pedido foi aceito (200): sem o campo `tools` e efêmero, com x-ai-core-store: false (cen. 5);
  5. a timeline de status chegou e ficou gravada na mensagem (`statusHistory`), da preparação à linha de conclusão
     (008 FR-005a, x-ai-core-progress: status).

Só biblioteca padrão; lê a senha de desenvolvimento do .env (DEV_USERS_PASSWORD) sem exibi-la. Rode da raiz do
agentic-deploy.
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
import uuid
from http.cookiejar import CookieJar, DefaultCookiePolicy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORM = re.compile(r'<form method="post" action="(/oauth2/login)">')
HIDDEN = re.compile(r'<input type="hidden" name="([a-z_]+)" value="([^"]*)"')
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
        # Com `AI_CORE_PUBLIC_URL` em https, o cookie de sessão da plataforma é `Secure`; os navegadores o mandam para
        # http://localhost (contexto seguro), mas o cookiejar do Python só por https.
        self.jar = CookieJar(policy=DefaultCookiePolicy(secure_protocols=("https", "wss", "http")))
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        # O Open WebUI redireciona para o /oauth2/authorize da plataforma, que mostra a página de login.
        response = self.opener.open(f"{WEBUI}/oauth/oidc/login", timeout=30)
        page = response.read().decode("utf-8")
        form = FORM.search(page)
        if form is None:
            fail(f"{user}: a página de login da plataforma não apareceu (em {response.geturl()})")
        fields = {name: html.unescape(value) for name, value in HIDDEN.findall(page)}
        fields |= {"identifier": user, "password": CONFIG["DEV_USERS_PASSWORD"]}
        data = urllib.parse.urlencode(fields).encode()
        # Login aceito → a plataforma volta ao callback do Open WebUI com o código, e ele abre a sessão.
        self.opener.open(urllib.parse.urljoin(response.geturl(), form.group(1)), data=data, timeout=30).read()
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

    def chat(self, model: str, content: str, timeout: float = 90) -> dict[str, object]:
        """Uma mensagem como a tela de chat do v0.12 a manda (`Chat.svelte`): conversa salva, `chat_id`, `session_id`,
        `model_item`, `features` (memória ligada, como o padrão) e `background_tasks`. É o `session_id` que liga as
        ferramentas embutidas do Open WebUI; com `chat_id`, a resposta é gravada na conversa, e é de lá que se lê — o
        texto e a timeline de status (`statusHistory`)."""
        item = next(m for m in self.get("/api/models")["data"] if m["id"] == model)  # type: ignore[index]
        chat = self.post(
            "/api/v1/chats/new",
            {"chat": {"title": "check-webui", "models": [model], "messages": [], "history": {"messages": {}}}},
        )
        chat_id = chat["id"]  # type: ignore[index]
        user_id, answer_id = str(uuid.uuid4()), str(uuid.uuid4())
        body = {
            "stream": True,
            "model": model,
            "messages": [{"role": "user", "content": content}],
            "params": {"model_controls": {}},
            "tool_ids": [],
            "tool_servers": [],
            "features": {
                "voice": False,
                "image_generation": False,
                "code_interpreter": False,
                "web_search": False,
                "memory": True,
            },
            "variables": {},
            "model_item": item,
            "session_id": f"check-webui-{self.user}",
            "chat_id": chat_id,
            "id": answer_id,
            "parent_id": user_id,
            "user_message": {"id": user_id, "role": "user", "content": content, "parentId": None},
            "background_tasks": {"title_generation": True, "tags_generation": True, "follow_up_generation": True},
        }
        self.post("/api/chat/completions", body)
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(2)
            saved = self.get(f"/api/v1/chats/{chat_id}")
            message = saved["chat"]["history"]["messages"].get(answer_id) or {}  # type: ignore[index]
            if message.get("error"):
                fail(f"{self.user}: o Open WebUI mostrou erro: {message['error']}")
            if message.get("done"):
                return dict(message)
        fail(f"{self.user}: a resposta não chegou em {timeout:.0f} s")
        return {}

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

    print("\n== 2. uma mensagem pelo Open WebUI chega à plataforma, montada como a tela de chat a monta")
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 1))
    mensagem = bia.chat("interno", MESSAGE)
    texto = str(mensagem.get("content") or "")
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

    print("\n== 4. pedido efêmero e sem ferramentas: o pedido foi aceito pela plataforma")
    if not pedidos[0].rstrip().endswith("200 OK"):
        fail(f"a plataforma recusou o pedido do Open WebUI: {pedidos[0].strip()}")
    print("200 OK — sem `tools` (recusado com 400) e sem conversa gravada (x-ai-core-store: false)")

    print("\n== 5. a timeline de status (x-ai-core-progress: status)")
    historico = mensagem.get("statusHistory")
    timeline = [item for item in historico if isinstance(item, dict)] if isinstance(historico, list) else []
    for item in timeline:
        print(f"  {'●' if item.get('done') else '◌'} {item.get('description')}")
    descricoes = [str(item.get("description", "")) for item in timeline]
    if not descricoes or descricoes[0] != "Preparando o contexto da pergunta…":
        fail("a timeline não começou pela preparação do contexto")
    if not any(linha.startswith("Resposta de ") for linha in descricoes):
        fail("a timeline não nomeia o modelo que gerou a resposta")
    if not descricoes[-1].startswith("Concluído em ") or timeline[-1].get("done") is not True:
        fail("a timeline não terminou com a linha de conclusão")

    print(
        "\nOK: cada usuário vê só os próprios Assistants, uma mensagem do Open WebUI é uma execução da plataforma, e o"
        " progresso dela aparece como timeline de status."
    )


if __name__ == "__main__":
    main()
