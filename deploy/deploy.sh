#!/bin/bash
# Déploie OsaMaps sur le VPS : web statique sous https://osalabs.fr/maps/ + serveur pm2 « osamaps » (port 3005).
#   ./deploy/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VPS=root@141.11.103.154
DEST=/var/www/osamaps

(cd web && npm run build)
ssh $VPS "mkdir -p $DEST/web $DEST/server/data"
rsync -az --delete web/dist/ $VPS:$DEST/web/
rsync -az --delete --exclude node_modules --exclude data server/ $VPS:$DEST/server/
scp -q deploy/nginx-osamaps.conf $VPS:/etc/nginx/snippets/osamaps.conf
ssh $VPS bash -s <<'REMOTE'
set -e
cd /var/www/osamaps/server && npm install --omit=dev --no-audit --no-fund --silent
SITE=/etc/nginx/sites-enabled/osalabs
grep -q "snippets/osamaps.conf" $SITE || sed -i '0,/    location \/ {/s//    include snippets\/osamaps.conf;\n\n    location \/ {/' $SITE
nginx -t && systemctl reload nginx
if pm2 describe osamaps >/dev/null 2>&1; then pm2 restart osamaps --update-env; else PORT=3005 pm2 start index.js --name osamaps --cwd /var/www/osamaps/server; fi
pm2 save >/dev/null
sleep 1; curl -sf http://127.0.0.1:3005/maps/api/health && echo
REMOTE
curl -sf https://osalabs.fr/maps/api/health && echo " ← en ligne"
