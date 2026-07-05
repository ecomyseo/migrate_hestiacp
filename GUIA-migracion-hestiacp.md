# Guía de migración HestiaCP → HestiaCP

Migración completa de un servidor HestiaCP (origen/viejo) a otro HestiaCP limpio
(destino/nuevo, recién instalado con solo el usuario `admin`).

## Resumen del método

HestiaCP **no tiene** un único comando "migra todo", pero sí las piezas oficiales:

| Comando | Qué hace |
|---|---|
| `v-backup-users` / `v-backup-user <u>` | Genera un `.tar` por usuario en `/backup/` |
| `v-restore-user <u> <fichero.tar>` | Restaura ese usuario en el destino (lo crea si no existe) |

Un backup de usuario **incluye**: dominios web (ficheros + configs + SSL), cuentas de
correo con el **correo real**, bases de datos, zonas DNS y cron.

Un backup de usuario **NO incluye** (por eso el script lo copia aparte):
plantillas custom, paquetes, config global (`hestia.conf`), SSL del hostname,
firewall/fail2ban, tuning de nginx/php/mysql y **las versiones de PHP instaladas**.

## Antes de empezar (obligatorio)

1. **Instala HestiaCP en el destino** con el **mismo stack** que el origen
   (nginx solo, o nginx+apache) y misma versión de Hestia si es posible.
2. **Instala las mismas versiones de PHP** en el destino. Es el fallo nº1: si un
   dominio del origen usa `php8.1` y el destino no la tiene, el restore falla o
   queda mal servido. El script detecta cuáles faltan (fase `check`) y te da los
   comandos `v-add-web-php X.Y` para instalarlas.
3. **Clave SSH root del origen → destino**:
   ```bash
   ssh-copy-id -p 22 root@IP_DESTINO
   ```
4. Espacio libre en `/backup` en ambos servidores.

## Uso del script

Copia `migrate-hestiacp.sh` al **servidor ORIGEN** y ejecútalo ahí:

```bash
chmod +x migrate-hestiacp.sh

# 1) Comprobar todo (conexión, versiones Hestia, PHP, stack web, usuarios):
./migrate-hestiacp.sh --host IP_DESTINO --check

# 2) Simular la migración completa (NO ejecuta nada, solo muestra):
./migrate-hestiacp.sh --host IP_DESTINO --all

# 3) Ejecutarla de verdad:
./migrate-hestiacp.sh --host IP_DESTINO --all --go
```

Por seguridad **todo es simulación (dry-run) hasta que añades `--go`**.

### Fases sueltas (si prefieres control paso a paso)

```bash
./migrate-hestiacp.sh --host IP --check --go
./migrate-hestiacp.sh --host IP --prep --go        # paquetes + plantillas custom
# --> aquí instala en el DESTINO las versiones PHP que el check marcó como faltantes
./migrate-hestiacp.sh --host IP --backup --go      # v-backup-users en origen
./migrate-hestiacp.sh --host IP --transfer --go    # rsync de los .tar
./migrate-hestiacp.sh --host IP --restore --go     # restore en el destino
./migrate-hestiacp.sh --host IP --verify --go      # comparar resultado
```

### Opciones

| Opción | Descripción |
|---|---|
| `--host <ip>` | IP/dominio del destino (**obligatorio**) |
| `--port <n>` | Puerto SSH destino (def. 22) |
| `--user <u>` | Usuario SSH destino (def. root) |
| `--exclude "a b"` | Usuarios a NO migrar (def. `admin`, que ya existe en destino) |
| `--go` | Ejecuta de verdad (sin esto, simulación) |

Todo queda registrado en `./logs/migracion-FECHA.log`.

## Después de migrar (manual, no va en backups)

- **Let's Encrypt**: re-emite certificados de cada dominio cuando el DNS ya apunte
  al nuevo servidor: `v-add-letsencrypt-domain <user> <dominio>`.
- **DNS / apuntar dominios**: cambia los registros A / los nameservers al destino.
  Hazlo **al final**, cuando hayas verificado que todo restauró bien.
- **Correo (DKIM/SPF)**: las claves DKIM van en el backup, pero revisa que el
  registro DNS DKIM/SPF apunte al nuevo IP.
- **Hostname del servidor y su SSL**: reconfigúralo en el destino (no se migra).
- **Firewall / fail2ban / tuning**: revisa reglas custom y `my.cnf`/`php.ini` si
  tenías ajustes especiales.
- **Prueba el login** de cada panel de usuario y navega los sitios antes de tumbar
  el servidor viejo.

## Método manual equivalente (sin el script)

Si quieres hacerlo a mano, es exactamente esto:

```bash
# En el ORIGEN:
v-backup-users
rsync -az -e ssh /backup/*.tar root@IP_DESTINO:/backup/

# En el DESTINO (bucle oficial que coge el tar más nuevo de cada usuario):
for i in $(ls -c1 /backup/*.tar | sed -E "s#^/backup/(.+)\..+tar#\1#" | sort -u); do
  fbackup="$(ls -rt -c1 /backup/$i.*tar | tail -n1 | awk -F/ '{print $NF}')"
  /usr/local/hestia/bin/v-restore-user "$i" "$fbackup"
done
```

## Notas importantes

- **Prueba primero con 1 usuario** antes de lanzar la migración completa.
- Si el origen usa backups **restic** (incrementales remotos), la clave de cifrado
  está en `/usr/local/hestia/data/users/{user}/restic.conf`; guárdala aparte. Este
  script usa backups **.tar** locales, que son autocontenidos y no la necesitan.
- No cambies el DNS hasta haber verificado el destino; así el origen sigue sirviendo
  mientras pruebas.

## Fuentes

- [Backup & Restore — HestiaCP docs](https://hestiacp.com/docs/server-administration/backup-restore)
- [CLI Reference — HestiaCP docs](https://hestiacp.com/docs/reference/cli)
- [How to migrate all users to another HestiaCP — Forum](https://forum.hestiacp.com/t/how-to-migrate-all-users-to-another-hestiacp/15167)
- [Migration to New VPS Server — Forum](https://forum.hestiacp.com/t/migration-to-new-vps-server/2833)
