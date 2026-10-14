#!/usr/bin/env bash
#
# Pubblica l'app TV sul server: copia `app/` nella cartella servita da nginx
# (vedi server/nginx-curfs-tv.conf). La TV la ricarica alla prossima apertura.
#
#   CURFS_TV_TARGET=utente@server:/percorso/curfs-tv ./deploy.sh
#   CURFS_TV_SSH="-i ~/.ssh/chiave" per una chiave SSH particolare.

set -euo pipefail
cd "$(dirname "$0")"
: "${CURFS_TV_TARGET:?imposta CURFS_TV_TARGET=utente@server:/percorso/curfs-tv}"
rsync -rlt --delete --exclude '.DS_Store' -e "ssh ${CURFS_TV_SSH:-}" app/ "$CURFS_TV_TARGET/"
echo "Pubblicata in $CURFS_TV_TARGET"
