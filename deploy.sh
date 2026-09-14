#!/bin/bash

# RoomVox Deployment Script
# Deploys to a dockerised Nextcloud test server: dev.rikdekker.nl or next.voxcloud.nl

set -e

# deploy.conf is no longer required: both targets below carry their own host,
# user, key and container. It is still sourced when present, for anything else
# a local setup may define — note the case block below wins for the variables
# it sets, so a host or key from deploy.conf does NOT override a target.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/deploy.conf" ]; then
    source "$SCRIPT_DIR/deploy.conf"
fi

# Configuration
APP_NAME="roomvox"
LOCAL_PATH="$(pwd)"

# Server selection. Both targets run Nextcloud in Docker, so the app goes into
# the bind-mounted custom_apps directory on the host and every occ call runs
# inside the container. They differ in who we log in as: ax42 has root SSH
# disabled (login as rik, use sudo), voxcloud-srv is key-only root.
case "${1:-dev}" in
    dev|"")
        REMOTE_HOST="178.63.205.103"          # ax42
        REMOTE_USER="rik"
        SSH_KEY="~/.ssh/hetzner_ed25519"
        SUDO="sudo"
        SERVER_NAME="dev.rikdekker.nl"
        DOCKER_CONTAINER="nc-dev"
        REMOTE_PATH="/opt/docker/nc-dev/app/custom_apps"
        PUBLIC_URL="https://dev.rikdekker.nl"
        ;;
    next)
        REMOTE_HOST="78.47.117.240"           # voxcloud-srv
        REMOTE_USER="root"
        SSH_KEY="~/.ssh/hetzner_ed25519"
        SUDO=""
        SERVER_NAME="next.voxcloud.nl"
        DOCKER_CONTAINER="nc-next"
        REMOTE_PATH="/opt/docker/nc-next/app/custom_apps"
        PUBLIC_URL="https://next.voxcloud.nl"
        ;;
    *)
        echo "Unknown server: $1"
        echo "Usage: ./deploy.sh [dev|next]  (default: dev)"
        echo "  dev  — dev.rikdekker.nl   (ax42, container nc-dev,  Nextcloud 34)"
        echo "  next — next.voxcloud.nl   (voxcloud-srv, nc-next,   Nextcloud 35)"
        exit 1
        ;;
esac

# Extract version from package.json
VERSION=$(grep '"version"' package.json | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')

echo "RoomVox Deployment Script"
echo "=============================="
echo "Version: $VERSION"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"

# Files and folders to include in deployment
INCLUDE_ITEMS=(
    "appinfo"
    "lib"
    "l10n"
    "templates"
    "css"
    "img"
    "js"
    "vendor"
    "composer.json"
    "LICENSE"
    "README.md"
)

echo ""
echo "Step 1: Building frontend..."

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
    echo "  Installing dependencies..."
    npm install
fi

# Build
npm run build

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Build completed"

echo ""
echo "Step 2: Creating deployment package..."

# Create temporary directory
TEMP_DIR=$(mktemp -d)
DEPLOY_DIR="$TEMP_DIR/$APP_NAME"
mkdir -p "$DEPLOY_DIR"

# Copy files
for item in "${INCLUDE_ITEMS[@]}"; do
    if [ -e "$LOCAL_PATH/$item" ]; then
        echo "  Copying $item..."
        cp -r "$LOCAL_PATH/$item" "$DEPLOY_DIR/"
    else
        echo "  Warning: $item not found, skipping..."
    fi
done

# Create tarball
TARBALL="$TEMP_DIR/${APP_NAME}.tar.gz"
echo "  Creating tarball..."
cd "$TEMP_DIR"
tar -czf "$TARBALL" "$APP_NAME"

echo "Deployment package created"

echo ""
echo "Step 3: Deploying to server..."
echo "  Server: $REMOTE_HOST"
echo "  Path: $REMOTE_PATH/$APP_NAME"

# Upload tarball
echo "  Uploading package..."
scp -i "$SSH_KEY" "$TARBALL" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/${APP_NAME}.tar.gz"

# Extract and setup on server
echo "  Extracting on server..."
ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" << EOF
    set -e

    $SUDO mkdir -p $REMOTE_PATH

    # Backup existing installation if present
    if [ -d "$REMOTE_PATH/$APP_NAME" ]; then
        echo "  Backing up existing installation..."
        BACKUP_NAME="${APP_NAME}.backup.\$(date +%Y%m%d_%H%M%S)"
        $SUDO mv $REMOTE_PATH/$APP_NAME "/tmp/\$BACKUP_NAME" || true
        echo "  Backup saved to /tmp/\$BACKUP_NAME"
    fi

    # Extract new version
    echo "  Extracting new version..."
    $SUDO tar -xzf /tmp/${APP_NAME}.tar.gz -C $REMOTE_PATH

    # Permissions: www-data inside the container is uid/gid 33. Naming the user
    # would resolve against the HOST's passwd, which is a different mapping.
    echo "  Setting permissions..."
    $SUDO chown -R 33:33 $REMOTE_PATH/$APP_NAME
    $SUDO chmod -R 755 $REMOTE_PATH/$APP_NAME

    # Clean up
    $SUDO rm -f /tmp/${APP_NAME}.tar.gz

    # Remove old backups, keep only the 2 most recent
    echo "  Cleaning up old backups..."
    $SUDO bash -c 'ls -d /tmp/${APP_NAME}.backup.* 2>/dev/null | sort -r | tail -n +3 | xargs -r rm -rf'

    echo "  Files deployed"
EOF

echo ""
echo "Step 4: Enabling app and clearing cache..."
ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" << EOF
    set -e

    # Disable and re-enable app to refresh routes
    echo "  Disabling app..."
    $SUDO docker exec -u www-data $DOCKER_CONTAINER php occ app:disable $APP_NAME || true

    echo "  Enabling app..."
    $SUDO docker exec -u www-data $DOCKER_CONTAINER php occ app:enable $APP_NAME || true

    # Bust the browser asset cache. The cache-buster is md5(appVersion), so a
    # release that keeps the same version number would otherwise serve stale
    # JS chunks against fresh PHP.
    echo "  Updating asset fingerprint..."
    $SUDO docker exec -u www-data $DOCKER_CONTAINER php occ maintenance:data-fingerprint || true

    # Clear OPcache — PHP keeps the previous bytecode until Apache restarts.
    echo "  Restarting Apache in container (OPcache clear)..."
    $SUDO docker exec $DOCKER_CONTAINER bash -c 'apachectl -k graceful' 2>/dev/null || true

    echo "  App enabled and cache cleared"
EOF

echo ""
echo "Step 5: Health check..."
HEALTH_CHECK=$(ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" "$SUDO docker exec $DOCKER_CONTAINER curl -s -o /dev/null -w '%{http_code}' http://localhost/apps/roomvox/ 2>/dev/null || echo '000'")

if [ "$HEALTH_CHECK" = "200" ] || [ "$HEALTH_CHECK" = "302" ] || [ "$HEALTH_CHECK" = "303" ]; then
    echo "  Health check passed (HTTP $HEALTH_CHECK)"
else
    echo "  Health check returned HTTP $HEALTH_CHECK (may require login)"
fi

# Verify deployed version
echo ""
echo "Step 6: Verifying deployed version..."
DEPLOYED_VERSION=$(ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" "$SUDO grep '<version>' $REMOTE_PATH/$APP_NAME/appinfo/info.xml | sed 's/.*<version>\([^<]*\)<\/version>.*/\1/'")

# What Nextcloud itself thinks is installed — this is what the app list shows.
OCC_VERSION=$(ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" "$SUDO docker exec -u www-data $DOCKER_CONTAINER php occ app:list 2>/dev/null | grep -A0 ' $APP_NAME:' | sed 's/.*: //'" | tr -d '[:space:]')
echo "  Version according to occ: ${OCC_VERSION:-unknown}"
echo "  Deployed version: $DEPLOYED_VERSION"

if [ "$VERSION" = "$DEPLOYED_VERSION" ]; then
    echo "  Version matches!"
else
    echo "  Version mismatch! Local: $VERSION, Deployed: $DEPLOYED_VERSION"
fi

# Cleanup local temp files
rm -rf "$TEMP_DIR"

echo ""
echo "Deployment completed successfully!"
echo ""
echo "Summary:"
echo "  App Name: $APP_NAME"
echo "  Version: $DEPLOYED_VERSION"
echo "  Server: $REMOTE_HOST"
echo "  Status: Deployed and enabled"
echo ""
echo "Access RoomVox at:"
echo "  $PUBLIC_URL"
echo ""
echo "Rollback (if needed):"
echo "  ssh ${REMOTE_USER}@${REMOTE_HOST} 'ls -la /tmp/${APP_NAME}.backup.*'"
echo "  ssh ${REMOTE_USER}@${REMOTE_HOST} '$SUDO rm -rf $REMOTE_PATH/$APP_NAME && $SUDO mv /tmp/${APP_NAME}.backup.YYYYMMDD_HHMMSS $REMOTE_PATH/$APP_NAME'"
echo ""
echo "View logs:"
echo "  ssh ${REMOTE_USER}@${REMOTE_HOST} '$SUDO docker exec -u www-data $DOCKER_CONTAINER tail -f data/nextcloud.log'"
echo ""
