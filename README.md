# migrate_hestiacp
Script Bash para migrar un servidor HestiaCP completo a otro HestiaCP limpio entre dos VPS. Usa los comandos oficiales (v-backup-user/v-restore-user) + rsync y cubre lo que los backups no incluyen: paquetes, plantillas custom y versiones PHP. Modo simulación por defecto.
