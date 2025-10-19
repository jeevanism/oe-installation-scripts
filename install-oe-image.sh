#!/bin/bash

# OpenEyes Docker Image Installation Script
# This script pulls the pre-built OpenEyes image from Docker Hub and runs it

set -e # Exit immediately if a command exits with a non-zero status

echo "=========================================="
echo "OpenEyes Docker Image Installation Script"
echo "=========================================="

# Check if Docker and Docker Compose are available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    exit 1
fi

if ! command -v docker compose &> /dev/null; then
    echo "Error: Docker Compose is not available"
    exit 1
fi

echo "✓ Docker and Docker Compose are available"

# Navigate to the current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Current directory: $(pwd)"

# Define compose file for the image-based setup
COMPOSE_FILE="docker-compose-oe-image.yml"

# Check for static compose file (NEW CHECK)
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: Required Docker Compose file not found: $COMPOSE_FILE"
    echo "Please ensure the static file is in the same directory as this script."
    exit 1
fi

echo "✓ Found static docker-compose configuration for OpenEyes image"

# Step 1: Pull the images from Docker Hub
echo
echo "Step 1: Pulling required images from Docker Hub..."
# Explicit pull commands ensure images are downloaded early, but they are optional
# as 'docker compose up' will also pull them. We keep them for verbosity.
docker pull codewasher/oe-docker:latest
docker pull mariadb:10.6

# Step 2: Start the database service first to ensure it's ready
echo
echo "Step 2: Starting database service..."
# Using --wait ensures the command doesn't proceed until the service is healthy
# This replaces the sleep and subsequent health check
docker compose -f "$COMPOSE_FILE" up -d --wait db
echo "✓ Database service is running and healthy"

# Step 3: Start the application service
echo
echo "Step 3: Starting OpenEyes application service..."
docker compose -f "$COMPOSE_FILE" up -d app

# Wait for app to be somewhat ready
sleep 10

# Step 4: Prepare the database
echo
echo "Step 4: Preparing database..."
echo "Dropping and recreating database..."
# Use correct variable names for database credentials (openeyesroot/openeyes)
docker compose -f "$COMPOSE_FILE" exec db mysql -uroot -popeneyesroot -e "DROP DATABASE IF EXISTS openeyes; CREATE DATABASE openeyes; GRANT ALL PRIVILEGES ON openeyes.* TO 'openeyes'@'%' IDENTIFIED BY 'openeyes'; FLUSH PRIVILEGES;"
echo "✓ Database prepared"

# Step 5: Import sample database
echo
echo "Step 5: Importing sample database..."
# Use openeyes/openeyes credentials for database import
if [ -f "sample_db.sql" ]; then
    echo "Found existing sample_db.sql file, importing..."
    docker compose -f "$COMPOSE_FILE" exec -T db mysql -u"openeyes" -p"openeyes" "openeyes" < sample_db.sql
    echo "✓ Sample database imported successfully"
elif [ -f "sample_db.zip" ]; then
    echo "Found sample_db.zip, extracting and importing..."
    # The file is actually gzipped, not zipped, so use zcat
    zcat sample_db.zip > sample_db.sql
    if [ -f "sample_db.sql" ]; then
        docker compose -f "$COMPOSE_FILE" exec -T db mysql -u"openeyes" -p"openeyes" "openeyes" < sample_db.sql
        echo "✓ Sample database imported successfully"
    else
        echo "✗ Could not create sample_db.sql after extracting from zip"
        exit 1
    fi
else
    echo "Sample database not found. Downloading..."
    DOWNLOAD_URL="https://github.com/AppertaFoundation/openeyes-sample-db/raw/refs/heads/release/v6.8.0/sql/sample_db.zip"

    if command -v curl >/dev/null 2>&1; then
        echo "Downloading sample database using curl..."
        curl -L -o sample_db.zip "$DOWNLOAD_URL"
    elif command -v wget >/dev/null 2>&1; then
        echo "Downloading sample database using wget..."
        wget "$DOWNLOAD_URL" -O sample_db.zip
    else
        echo "✗ Neither curl nor wget is available to download the sample database"
        echo "Please manually download the sample database and place it in this directory."
        exit 1
    fi

    # Extract using zcat (the file is gzipped despite .zip extension) and import
    echo "Extracting downloaded sample database..."
    zcat sample_db.zip > sample_db.sql
    if [ -f "sample_db.sql" ]; then
        echo "Importing downloaded sample database..."
        docker compose -f "$COMPOSE_FILE" exec -T db mysql -u"openeyes" -p"openeyes" "openeyes" < sample_db.sql
        echo "✓ Sample database imported successfully"
    else
        echo "✗ Could not create sample_db.sql after downloading and extracting"
        exit 1
    fi
fi

# Step 6: Verify installation
echo
echo "Step 6: Verifying installation..."
if docker compose -f "$COMPOSE_FILE" exec db mysql -u"openeyes" -p"openeyes" -e "USE openeyes; SELECT COUNT(*) as user_count FROM user;" > /dev/null 2>&1; then
    USER_COUNT=$(docker compose -f "$COMPOSE_FILE" exec -t db mysql -u"openeyes" -p"openeyes" -sN -e "USE openeyes; SELECT COUNT(*) FROM user;")
    echo "✓ Database verification successful - Found $USER_COUNT users"
else
    echo "⚠ Database verification failed"
    # Try alternative verification
    TABLE_COUNT=$(docker compose -f "$COMPOSE_FILE" exec -t db mysql -u"openeyes" -p"openeyes" -sN -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'openeyes';")
    echo "Found $TABLE_COUNT tables in the database"
fi

# Step 7: Generate assets to fix CSS/JS issues
echo
echo "Step 7: Generating application assets..."
# Wait a bit more to ensure app is fully ready
sleep 10
# Access the homepage to trigger asset generation
echo "Triggering asset generation by accessing the application..."
curl -s -f http://localhost:8080/ > /dev/null 2>&1 || echo "Initial access attempt (expected to fail for assets generation)"

# Check if assets are now being generated
echo "Checking asset directories..."
ASSET_DIRS=$(docker compose -f "$COMPOSE_FILE" exec app ls /var/www/html/assets/ 2>/dev/null || echo "")
if [ -n "$ASSET_DIRS" ]; then
    echo "✓ Assets directory has contents."
else
    echo "ℹ Assets directory may still be generating, waiting..."
    sleep 20
fi

# Step 8: Final status check
echo
echo "Step 8: Final status check..."
if curl -f http://localhost:8080/ > /dev/null 2>&1; then
    echo "✓ OpenEyes is accessible at http://localhost:8080/"
else
    echo "ℹ OpenEyes may still be starting up, please wait a moment..."
    echo "You can check the status with: docker compose -f $COMPOSE_FILE logs -f"
fi

echo
echo "=========================================="
echo "OpenEyes Installation Complete! 🚀"
echo "=========================================="
echo
echo "OpenEyes is now running at: http://localhost:8080/"
echo
echo "Default login credentials (from sample database):"
echo "  Username: admin"
echo "  Password: admin"
echo
echo "Docker services status:"
docker compose -f "$COMPOSE_FILE" ps
echo
echo "To stop OpenEyes: docker compose -f $COMPOSE_FILE down"
echo "To restart OpenEyes: docker compose -f $COMPOSE_FILE up -d"
echo "To view logs: docker compose -f $COMPOSE_FILE logs -f"
echo
