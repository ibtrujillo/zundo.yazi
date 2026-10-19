# zundo.yazi plan

## Estado

- `u`: restaura el último lote de la papelera (freedesktop, vía API nativa de yazi).
- Confirm yes/no con lista, iconos (`th.icon`, mismo patrón que zarchive): D dir, F archivo, L symlink.
- Conflictos:
  - dir sobre dir: fusión recursiva.
  - archivo sobre archivo: reemplazo tras confirmación.
  - no-dir sobre dir existente: bloqueado. Antes de restaurar se muestra la lista con causa (`refuses to replace directory`) y se pregunta: sí restaura el resto (el bloqueado queda en papelera), no cancela sin cambios.
  - symlink sobre existente: se reemplaza el link (el destino no se toca). Prompt dice "Replace N symlink(s)"; archivos reales dicen "PERMANENTLY deleted".
- Símbolo `u` en `keymap.toml`. Redo (`U`) descartado.
- Tests: `nix run nixpkgs#lua5_4 -- test.lua` (stub de API yazi + escenarios + cobertura 100%).

## Pendiente

- [x] Iconos del confirm verificados en yazi real (screenshots: overwrite = icono link nativo U+F481 gris `#9e9e9e`, restore = dir nativo U+E5FF azul `#03a9f4`; reglas en `if = "link"` / `if = "dir"` del preset compilado en yazi 26.9.1).
- [ ] Reiniciar yazi y probar bloqueo en real.
- [ ] Verificar en yazi real el restore del lote con symlink (`files/1.2`).
- [ ] Commit solo tras confirmación del usuario. Aplicar `dotbot` después del commit.
- [ ] Limpiar estado en disco: `files/1.2` (symlink) y `files/1` siguen en la papelera. No tocar sin instrucción.
- [ ] Symlink en `evidence/1` apunta a `Wallpapers/dark`: se reemplaza al restaurar `files/1` (dir). Confirmar que es lo deseado.
