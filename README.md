# agentic-deploy

Repositório de instalação da plataforma Agentic AI (spec 002, US5; ADR-009, ADR-022): o Dockerfile constrói o core a
partir de uma tag do `agentic-app`, instala os packs recebidos por build-arg e roda `ai-core packs check` no build —
pack incompatível falha o build, não a produção. A especificação mora no `agentic-app` (`specs/002-core-pack-runtime/`),
onde este repositório é o submódulo `agentic-deploy/`.
