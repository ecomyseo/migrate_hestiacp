# hestia-migration

Script en Bash para **migrar un servidor HestiaCP completo a otro HestiaCP limpio**
entre dos VPS, usando los comandos oficiales de Hestia (`v-backup-user` /
`v-restore-user`) + `rsync`, y cubriendo además lo que los backups de usuario
**no** incluyen (paquetes, plantillas custom y versiones de PHP).

Se ejecuta en el servidor **origen** (el viejo) y empuja todo al **destino**
(el nuevo, recién instalado con solo el usuario `admin`) por SSH. Trabaja en
**modo simulación por defecto**: no toca nada hasta que añades `--go`.

## ¿Qué migra?

- **De fábrica en Hestia** (via `v-backup-user`): dominios web (ficheros, configs,
  SSL), cuentas de correo con el **correo real**, bases de datos, zonas DNS y cron.
- **Extra que el script añade** (los backups no lo llevan): paquetes de usuario,
  plantillas custom y detección de las versiones PHP que faltan en el destino.

## Uso rápido

```bash
# En el servidor ORIGEN:
chmod +x migrate-hestiacp.sh

./migrate-hestiacp.sh --host IP_DESTINO --check      # comprobaciones previas
./migrate-hestiacp.sh --host IP_DESTINO --all        # simula la migracion completa
./migrate-hestiacp.sh --host IP_DESTINO --all --go   # la ejecuta de verdad
```

Todo queda registrado en `./logs/migracion-FECHA.log`.

## Fases

| Fase | Acción |
|---|---|
| `check` | Comprueba SSH, que ambos sean Hestia, y compara versiones (Hestia, PHP, stack web) |
| `prep` | Copia paquetes y plantillas custom; avisa de versiones PHP faltantes |
| `backup` | `v-backup-users` en el origen (genera `/backup/*.tar`) |
| `transfer` | `rsync` de los `.tar` al `/backup/` del destino |
| `restore` | Bucle `v-restore-user` en el destino (coge el tar más reciente de cada usuario) |
| `verify` | Compara usuarios y nº de dominios origen vs destino |

## Requisitos

- HestiaCP en ambos servidores, **mismo stack** (nginx solo, o nginx+apache).
- **Mismas versiones de PHP** en el destino (el script detecta las que faltan).
- Clave SSH root del origen → destino: `ssh-copy-id -p 22 root@IP_DESTINO`.
- Espacio libre en `/backup` en ambos.

## Documentación

Guía completa, opciones, método manual equivalente y pasos posteriores
(Let's Encrypt, DNS, hostname): **[GUIA-migracion-hestiacp.md](GUIA-migracion-hestiacp.md)**.

## Aviso

Prueba primero con **un solo usuario** y **no cambies el DNS** hasta verificar que
el destino sirve todo correctamente. El autor no se responsabiliza de pérdidas de
datos: haz copias antes de operar en producción.

## Licencia

AFL-3.0 — Ecom Experts · 2026
