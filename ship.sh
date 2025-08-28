#!/usr/bin/env bash

set -euo pipefail

# Load environment variables from .env file
if [[ -f ".env" ]]; then
    echo "📋 Loading environment variables from .env..."
    # Load .env and remove quotes
    set -a
    source <(sed 's/"//g' .env)
    set +a
else
    echo "❌ .env file not found!"
    exit 1
fi

# Validate required environment variables
required_vars=(
    "TS_BUNNY_REGION"
    "TS_BUNNY_BUCKET" 
    "TS_BUNNY_BUCKET_TOKEN"
    "TS_BUNNY_PULLZONE_ID"
    "TS_BUNNY_API_KEY"
    "TS_CLOUDFLARE_ZONE"
    "TS_CLOUDFLARE_API_KEY"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "❌ Required environment variable $var is not set!"
        exit 1
    fi
done

# Config
DIST_DIR="./"

# Timestamp
TIME=$(date +"%H:%M")
DATE=$(date +"%Y-%m-%d")
COMMIT_MSG="Ship dist $TIME at $DATE"

function push_repo() {
    echo "📦 Pushing dist to Git..."
    
    if [[ ! -d "$DIST_DIR" ]]; then
        echo "❌ Distribution directory '$DIST_DIR' does not exist!"
        exit 1
    fi
    
    # Check if this is a git repository (git should be in root)
    if [[ ! -d ".git" ]]; then
        echo "❌ Current directory is not a git repository!"
        exit 1
    fi
    
    git add "$DIST_DIR"
    git commit -m "$COMMIT_MSG" || echo "⚠️  Nothing to commit."
    git push origin HEAD
    echo "✅ Git push complete."
}

function upload_to_cdn() {
    echo "🚀 Uploading dist to BunnyCDN..."
    
    if [[ ! -d "$DIST_DIR" ]]; then
        echo "❌ Distribution directory '$DIST_DIR' does not exist!"
        exit 1
    fi

    # Upload files to BunnyCDN
    echo "🔍 Debug info:"
    echo "  Region: '$TS_BUNNY_REGION'"
    echo "  Bucket: '$TS_BUNNY_BUCKET'" 
    echo "  Token: '${TS_BUNNY_BUCKET_TOKEN:0:10}...'"
    echo "  Token length: ${#TS_BUNNY_BUCKET_TOKEN}"
    echo ""
    
    find "$DIST_DIR" -type f ! -path "$DIST_DIR/.git/*" ! -name ".git" | while read -r file; do
        relative_path="${file#$DIST_DIR/}"
        
        # Handle primary region (DE/Frankfurt) vs regional endpoints
        if [[ "$TS_BUNNY_REGION" == "de" || "$TS_BUNNY_REGION" == "primary" ]]; then
            remote_url="https://storage.bunnycdn.com/${TS_BUNNY_BUCKET}/${relative_path}"
        else
            remote_url="https://${TS_BUNNY_REGION}.storage.bunnycdn.com/${TS_BUNNY_BUCKET}/${relative_path}"
        fi
        echo "🟢 Uploading: $relative_path → $remote_url"

        # Try upload with verbose output on failure
        if ! curl --silent --show-error --fail --request PUT \
            --url "$remote_url" \
            --header "AccessKey: $TS_BUNNY_BUCKET_TOKEN" \
            --header "Content-Type: application/octet-stream" \
            --data-binary @"$file"; then
            echo "❌ Failed to upload: $relative_path"
            echo "🔍 Retrying with verbose output..."
            curl -v --request PUT \
                --url "$remote_url" \
                --header "AccessKey: $TS_BUNNY_BUCKET_TOKEN" \
                --header "Content-Type: application/octet-stream" \
                --data-binary @"$file"
            exit 1
        fi
    done

    echo "🟢 FLUSHING BUNNY CACHE: https://api.bunny.net/pullzone/${TS_BUNNY_PULLZONE_ID}/purgeCache"

    if ! curl --silent --show-error --fail --request POST \
        --url "https://api.bunny.net/pullzone/${TS_BUNNY_PULLZONE_ID}/purgeCache" \
        --header "AccessKey: $TS_BUNNY_API_KEY" \
        --header "content-type: application/json"; then
        echo "❌ Failed to flush Bunny cache"
        exit 1
    fi

    echo "🟢 FLUSHING CLOUDFLARE CACHE: https://api.cloudflare.com/client/v4/zones/${TS_CLOUDFLARE_ZONE}/purge_cache"
    
    if ! curl --silent --show-error --fail -X POST \
        "https://api.cloudflare.com/client/v4/zones/${TS_CLOUDFLARE_ZONE}/purge_cache" \
        -H 'Content-Type: application/json' \
        -H "X-Auth-Email: acamerondev@protonmail.com" \
        -H "X-Auth-Key: $TS_CLOUDFLARE_API_KEY" \
        -d '{"purge_everything": true}'; then
        echo "❌ Failed to flush Cloudflare cache"
        exit 1
    fi

    echo "✅ CDN upload complete."
}

function usage() {
    echo "Usage: $0 [repo|cdn|both]"
    echo ""
    echo "Commands:"
    echo "  repo  - Only push to git repository"
    echo "  cdn   - Only upload to CDN and flush caches"
    echo "  both  - Push to git and upload to CDN (default)"
    echo ""
    echo "Environment variables required in .env file:"
    for var in "${required_vars[@]}"; do
        echo "  $var"
    done
    exit 1
}

# Main execution
case "${1:-both}" in
    repo) 
        npm run minify && push_repo 
        ;;
    cdn) 
        npm run minify &&upload_to_cdn 
        ;;
    both) 
        npm run minify && push_repo && upload_to_cdn 
        ;;
    help|--help|-h)
        usage
        ;;
    *) 
        echo "❌ Invalid argument: $1"
        usage 
        ;;
esac

echo "🎉 Deployment complete!"