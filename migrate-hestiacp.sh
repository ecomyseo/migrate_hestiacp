#!/usr/bin/env bash
#
# migrate-hestiacp.sh
# ---------------------------------------------------------------------------
# Migracion COMPLETA de un servidor HestiaCP a otro HestiaCP limpio.
#
# Se ejecuta EN EL SERVIDOR ORIGEN (el viejo) y empuja todo al DESTINO
# (el nuevo, recien instalado con solo el usuario admin) via SSH/rsync.
#
# Estrategia (metodo oficial HestiaCP + extras que los backups NO incluyen):
#   1. check    -> comprueba SSH, que ambos sean Hestia, y compara versiones PHP.
#   2. prep     -> copia paquetes, plantillas custom y avisa de PHP faltantes.
#   3. backup   -> v-backup-users en origen (genera /backup/*.tar).
#   4. transfer -> rsync de los .tar al /backup/ del destino.
#   5. restore  -> bucle v-restore-user en el destino (SSH), coge el tar mas nuevo.
#   6. verify   -> lista usuarios/dominios en ambos y compara.
#
# Requisitos:
#   - Clave SSH root de ORIGEN -> DESTINO ya autorizada (ssh-copy-id).
#   - HestiaCP instalado en ambos (mismo tipo de stack: nginx / nginx+apache).
#   - Espacio en /backup en ambos servidores.
#
# Uso:
#   ./migrate-hestiacp.sh --host 1.2.3.4 [--port 22] [--all] [--fase] [--go]
#
# Por seguridad NADA se ejecuta de verdad sin --go (modo dry-run por defecto).
#
# Autor: Ecom Experts <ecomyseo@gmail.com>
# Licencia: AFL-3.0  |  2026
# ---------------------------------------------------------------------------

set -euo pipefail

# ============================ CONFIG POR DEFECTO ===========================
DEST_HOST=""                 # IP o dominio del servidor NUEVO (destino)
DEST_PORT="22"               # Puerto SSH del destino
DEST_USER="root"             # Usuario SSH del destino (root)
HESTIA="/usr/local/hestia"   # Ruta de instalacion de Hestia
BACKUP_DIR="/backup"         # Carpeta de backups de Hestia
LOG_DIR="./logs"             # Carpeta de logs (se crea si no existe)
DRYRUN=1                     # 1 = simular, 0 = ejecutar de verdad (--go)
EXCLUDE_USERS="admin"        # Usuarios a NO migrar (separados por espacio). admin ya existe en destino.
RUN_ALL=0
DO_CHECK=0; DO_PREP=0; DO_BACKUP=0; DO_TRANSFER=0; DO_RESTORE=0; DO_VERIFY=0

# ================================ COLORES ==================================
c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_b=$'\e[36m'; c_x=$'\e[0m'
LOGFILE=""

log()  { echo "${c_b}[*]${c_x} $*" | tee -a "$LOGFILE"; }
ok()   { echo "${c_g}[OK]${c_x} $*" | tee -a "$LOGFILE"; }
warn() { echo "${c_y}[!]${c_x} $*"  | tee -a "$LOGFILE"; }
err()  { echo "${c_r}[X]${c_x} $*"  | tee -a "$LOGFILE" >&2; }
die()  { err "$*"; exit 1; }

# Ejecuta un comando LOCAL (o lo imprime en dry-run)
run() {
  if [ "$DRYRUN" -eq 1 ]; then
    echo "${c_y}DRY-RUN local:${c_x} $*" | tee -a "$LOGFILE"
  else
    echo "${c_b}RUN local:${c_x} $*" | tee -a "$LOGFILE"
    eval "$@"
  fi
}

# Ejecuta un comando en el DESTINO por SSH (o lo imprime en dry-run)
rrun() {
  local cmd="$*"
  if [ "$DRYRUN" -eq 1 ]; then
    echo "${c_y}DRY-RUN remoto:${c_x} $cmd" | tee -a "$LOGFILE"
  else
    echo "${c_b}RUN remoto:${c_x} $cmd" | tee -a "$LOGFILE"
    ssh -p "$DEST_PORT" "${DEST_USER}@${DEST_HOST}" "$cmd"
  fi
}

# SSH silencioso que SIEMPRE se ejecuta (para lecturas/checks, no muta nada)
rquery() { ssh -p "$DEST_PORT" -o ConnectTimeout=10 "${DEST_USER}@${DEST_HOST}" "$@"; }

usage() {
  cat <<EOF
Uso: $0 --host <ip_destino> [opciones]

Conexion:
  --host <ip>       IP/dominio del servidor NUEVO (obligatorio)
  --port <n>        Puerto SSH destino (def. 22)
  --user <u>        Usuario SSH destino (def. root)
  --exclude "a b"   Usuarios a NO migrar (def. "admin")

Fases (si no indicas ninguna, usa --all):
  --check           Comprueba conectividad y versiones
  --prep            Copia paquetes, plantillas custom y avisa PHP faltante
  --backup          v-backup-users en el origen
  --transfer        rsync de los .tar al destino
  --restore         Restaura todos los usuarios en el destino
  --verify          Compara usuarios/dominios origen vs destino
  --all             Ejecuta todas las fases en orden

Seguridad:
  --go              EJECUTA de verdad (sin esto, todo es simulacion dry-run)
  -h | --help       Esta ayuda

Ejemplo real:
  $0 --host 203.0.113.10 --check
  $0 --host 203.0.113.10 --all            # simula la migracion completa
  $0 --host 203.0.113.10 --all --go       # la ejecuta de verdad
EOF
}

# =============================== ARGUMENTOS ================================
while [ $# -gt 0 ]; do
  case "$1" in
    --host) DEST_HOST="$2"; shift 2 ;;
    --port) DEST_PORT="$2"; shift 2 ;;
    --user) DEST_USER="$2"; shift 2 ;;
    --exclude) EXCLUDE_USERS="$2"; shift 2 ;;
    --check) DO_CHECK=1; shift ;;
    --prep) DO_PREP=1; shift ;;
    --backup) DO_BACKUP=1; shift ;;
    --transfer) DO_TRANSFER=1; shift ;;
    --restore) DO_RESTORE=1; shift ;;
    --verify) DO_VERIFY=1; shift ;;
    --all) RUN_ALL=1; shift ;;
    --go) DRYRUN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opcion desconocida: $1 (usa --help)" ;;
  esac
done

# Si no se pidio ninguna fase concreta, ejecutar todas
if [ $((DO_CHECK+DO_PREP+DO_BACKUP+DO_TRANSFER+DO_RESTORE+DO_VERIFY)) -eq 0 ]; then
  RUN_ALL=1
fi
if [ "$RUN_ALL" -eq 1 ]; then
  DO_CHECK=1; DO_PREP=1; DO_BACKUP=1; DO_TRANSFER=1; DO_RESTORE=1; DO_VERIFY=1
fi

[ -n "$DEST_HOST" ] || { usage; die "Falta --host <ip_destino>"; }

mkdir -p "$LOG_DIR"
LOGFILE="${LOG_DIR}/migracion-$(date +%Y%m%d-%H%M%S).log"
: > "$LOGFILE"

log "Log: $LOGFILE"
[ "$DRYRUN" -eq 1 ] && warn "MODO SIMULACION (dry-run). Nada se ejecuta. Anade --go para ir en serio."

# Lista de usuarios reales del origen, excluyendo los indicados
hestia_users() {
  local u
  for u in $("$HESTIA/bin/v-list-users" plain | awk '{print $1}'); do
    case " $EXCLUDE_USERS " in *" $u "*) continue ;; esac
    echo "$u"
  done
}

# ================================ FASE: CHECK ==============================
fase_check() {
  log "=== FASE 1/6: CHECK ==="

  [ -x "$HESTIA/bin/v-list-users" ] || die "Este servidor no parece HestiaCP (no existe $HESTIA/bin)."
  ok "Origen es HestiaCP."

  log "Probando SSH a ${DEST_USER}@${DEST_HOST}:${DEST_PORT} ..."
  if ! rquery "test -x $HESTIA/bin/v-list-users" 2>/dev/null; then
    die "No hay SSH sin password al destino, o el destino no es HestiaCP. Ejecuta antes: ssh-copy-id -p $DEST_PORT ${DEST_USER}@${DEST_HOST}"
  fi
  ok "SSH OK y destino es HestiaCP."

  # Comparar versiones de Hestia
  local vo vd
  vo=$(cat "$HESTIA/conf/hestia.conf" 2>/dev/null | grep -m1 VERSION | cut -d"'" -f2 || echo "?")
  vd=$(rquery "grep -m1 VERSION $HESTIA/conf/hestia.conf | cut -d\"'\" -f2" 2>/dev/null || echo "?")
  log "Version Hestia  origen=$vo  destino=$vd"
  [ "$vo" = "$vd" ] || warn "Las versiones de Hestia difieren. Recomendado igualarlas antes de restaurar."

  # Comparar versiones PHP instaladas (el fallo nº1 en migraciones)
  log "Comprobando versiones PHP (multiphp)..."
  local php_o php_d
  php_o=$(ls -1 /etc/php/ 2>/dev/null | grep -E '^[0-9]' | sort -u | tr '\n' ' ')
  php_d=$(rquery "ls -1 /etc/php/ 2>/dev/null | grep -E '^[0-9]' | sort -u | tr '\n' ' '" 2>/dev/null || echo "")
  log "PHP origen : ${php_o:-ninguna}"
  log "PHP destino: ${php_d:-ninguna}"
  local faltan=""
  local v
  for v in $php_o; do
    case " $php_d " in *" $v "*) : ;; *) faltan="$faltan $v" ;; esac
  done
  if [ -n "$faltan" ]; then
    warn "FALTAN versiones PHP en el destino:$faltan"
    warn "Instalalas en el DESTINO antes del restore, p.ej.:"
    for v in $faltan; do
      warn "   v-add-web-php $v"
    done
  else
    ok "Todas las versiones PHP del origen existen en el destino."
  fi

  # Comparar stack web (nginx solo vs nginx+apache)
  local web_o web_d
  web_o=$(grep -m1 "^WEB_SYSTEM" "$HESTIA/conf/hestia.conf" | cut -d"'" -f2 || echo "?")
  web_d=$(rquery "grep -m1 '^WEB_SYSTEM' $HESTIA/conf/hestia.conf | cut -d\"'\" -f2" 2>/dev/null || echo "?")
  local proxy_o proxy_d
  proxy_o=$(grep -m1 "^PROXY_SYSTEM" "$HESTIA/conf/hestia.conf" | cut -d"'" -f2 || echo "")
  proxy_d=$(rquery "grep -m1 '^PROXY_SYSTEM' $HESTIA/conf/hestia.conf | cut -d\"'\" -f2" 2>/dev/null || echo "")
  log "Stack web origen : WEB=$web_o PROXY=${proxy_o:-none}"
  log "Stack web destino: WEB=$web_d PROXY=${proxy_d:-none}"
  { [ "$web_o" = "$web_d" ] && [ "$proxy_o" = "$proxy_d" ]; } \
    || warn "El stack web difiere (nginx vs nginx+apache). Los dominios pueden quedar mal servidos si no coincide."

  # Usuarios a migrar
  log "Usuarios que se migraran (excluyendo: $EXCLUDE_USERS):"
  hestia_users | sed 's/^/     - /' | tee -a "$LOGFILE"
  ok "Check terminado."
}

# ================================ FASE: PREP ==============================
fase_prep() {
  log "=== FASE 2/6: PREP (paquetes + plantillas custom) ==="

  # Paquetes de usuario (los backups referencian el nombre del paquete; si no
  # existe en destino, el restore puede fallar). Se copian TODOS.
  log "Copiando paquetes de usuario ($HESTIA/data/packages/)..."
  run "rsync -az -e 'ssh -p $DEST_PORT' $HESTIA/data/packages/ ${DEST_USER}@${DEST_HOST}:$HESTIA/data/packages/"

  # Plantillas custom (web/proxy/dns/php/mail). Solo tiene sentido copiar las
  # que NO son del core. Copiamos todo el arbol; en un destino fresco es seguro.
  log "Copiando plantillas ($HESTIA/data/templates/)..."
  run "rsync -az -e 'ssh -p $DEST_PORT' $HESTIA/data/templates/ ${DEST_USER}@${DEST_HOST}:$HESTIA/data/templates/"

  # Fix de permisos en destino tras copiar data/
  rrun "chown -R admin:admin $HESTIA/data/packages $HESTIA/data/templates 2>/dev/null; $HESTIA/bin/v-update-sys-hestia-all >/dev/null 2>&1 || true"

  ok "Prep terminado. (Revisa arriba si faltaban versiones PHP: instalalas ahora en el destino.)"
}

# ================================ FASE: BACKUP =============================
fase_backup() {
  log "=== FASE 3/6: BACKUP en el origen ==="
  local u
  for u in $(hestia_users); do
    log "Backup de usuario: $u"
    run "$HESTIA/bin/v-backup-user $u"
  done
  ok "Backups generados en $BACKUP_DIR/"
  run "ls -lh $BACKUP_DIR/*.tar 2>/dev/null | tail -n 50"
}

# =============================== FASE: TRANSFER ===========================
fase_transfer() {
  log "=== FASE 4/6: TRANSFER (rsync de .tar al destino) ==="
  rrun "mkdir -p $BACKUP_DIR"
  # rsync solo de los .tar, con progreso y reanudable
  run "rsync -az --info=progress2 --partial -e 'ssh -p $DEST_PORT' $BACKUP_DIR/*.tar ${DEST_USER}@${DEST_HOST}:$BACKUP_DIR/"
  ok "Tars transferidos."
}

# ================================ FASE: RESTORE ===========================
fase_restore() {
  log "=== FASE 5/6: RESTORE en el destino ==="
  local u tarname
  for u in $(hestia_users); do
    # Nombre del tar mas reciente de ESE usuario, en el DESTINO
    tarname=$(rquery "ls -rt -c1 $BACKUP_DIR/${u}.*.tar 2>/dev/null | tail -n1 | awk -F/ '{print \$NF}'" || echo "")
    if [ -z "$tarname" ]; then
      warn "No hay backup en destino para '$u', se omite."
      continue
    fi
    log "Restaurando '$u' desde '$tarname'..."
    rrun "$HESTIA/bin/v-restore-user $u $tarname"
  done
  ok "Restore terminado."
}

# ================================ FASE: VERIFY ============================
fase_verify() {
  log "=== FASE 6/6: VERIFY (comparativa origen vs destino) ==="
  log "--- Usuarios ---"
  echo "ORIGEN :" | tee -a "$LOGFILE"; hestia_users | tee -a "$LOGFILE"
  echo "DESTINO:" | tee -a "$LOGFILE"
  rquery "$HESTIA/bin/v-list-users plain | awk '{print \$1}'" | tee -a "$LOGFILE" || true

  local u co cd
  log "--- Nº de dominios web por usuario ---"
  for u in $(hestia_users); do
    co=$("$HESTIA/bin/v-list-web-domains" "$u" plain 2>/dev/null | wc -l || echo 0)
    cd=$(rquery "$HESTIA/bin/v-list-web-domains $u plain 2>/dev/null | wc -l" 2>/dev/null || echo 0)
    printf '   %-16s origen=%-4s destino=%-4s %s\n' "$u" "$co" "$cd" \
      "$( [ "$co" = "$cd" ] && echo OK || echo '<-- DIFIERE' )" | tee -a "$LOGFILE"
  done
  ok "Verify terminado. Revisa arriba las diferencias."
  warn "Recuerda en el destino: re-emitir Let's Encrypt (v-add-letsencrypt-domain), revisar DNS/NS, DKIM y probar login de cada panel."
}

# ================================== MAIN ==================================
[ "$DO_CHECK"    -eq 1 ] && fase_check
[ "$DO_PREP"     -eq 1 ] && fase_prep
[ "$DO_BACKUP"   -eq 1 ] && fase_backup
[ "$DO_TRANSFER" -eq 1 ] && fase_transfer
[ "$DO_RESTORE"  -eq 1 ] && fase_restore
[ "$DO_VERIFY"   -eq 1 ] && fase_verify

echo
ok "Proceso finalizado."
[ "$DRYRUN" -eq 1 ] && warn "Era SIMULACION. Para ejecutar de verdad repite el comando con --go"
log "Log guardado en: $LOGFILE"
