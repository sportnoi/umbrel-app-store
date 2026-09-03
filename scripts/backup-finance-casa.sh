#!/bin/sh
# Online backup of Finance Casa's SQLite database.
#
# Uses sqlite3's backup API from inside the backend container, so the copy is
# consistent even while the app and the Telegram bot are both writing. Never
# plain-copy finance.db from the host while the app runs — two containers hold
# it open and you can capture a torn file.
#
# Run on the Umbrel host:   sudo sh scripts/backup-finance-casa.sh
set -eu

APP_DATA=/home/umbrel/umbrel/app-data/finance-casa
DEST=${FINANCE_CASA_BACKUP_DIR:-/home/umbrel/backups/finance-casa}
KEEP=${FINANCE_CASA_BACKUP_KEEP:-14}
CONTAINER=finance-casa_backend_1

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "error: $CONTAINER is not running — start the app first" >&2
  exit 1
fi

mkdir -p "$DEST"
STAMP=$(date +%Y-%m-%d-%H%M)

# .backup-tmp.db is written inside the bind mount, so it lands on the host at
# $APP_DATA/data/ where we can move it out.
docker exec "$CONTAINER" python -c "
import sqlite3
src = sqlite3.connect('/data/finance.db')
dst = sqlite3.connect('/data/.backup-tmp.db')
with dst:
    src.backup(dst)
dst.close(); src.close()
"

mv "$APP_DATA/data/.backup-tmp.db" "$DEST/finance-$STAMP.db"
gzip -f "$DEST/finance-$STAMP.db"
chmod 600 "$DEST/finance-$STAMP.db.gz"
echo "wrote $DEST/finance-$STAMP.db.gz"

# Retention: keep the newest $KEEP, delete the rest.
ls -1t "$DEST"/finance-*.db.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old"
  echo "pruned $old"
done
