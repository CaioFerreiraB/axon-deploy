"""Pack que declara uma versão de contrato que os contratos instalados não atendem (spec 002, US5 cen. 2)."""

from __future__ import annotations

from ai_core_contracts import PackBase, PackManifest


class IncompatiblePack(PackBase):
    name = "incompatible"
    contract_version = "0.2"

    def manifest(self) -> PackManifest:
        return PackManifest(name=self.name, version="0.1.0")
