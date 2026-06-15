#!/usr/bin/env bash
set -euo pipefail

# Admin Dashboard Build & Deploy Script
# Builds Flutter web version and optionally deploys to server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/web"
PROJECT_DIR="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}❌ $1${NC}"
}

# Check prerequisites
check_flutter() {
  if ! command -v flutter &> /dev/null; then
    log_error "Flutter not found in PATH"
    echo "Please install Flutter: https://flutter.dev/docs/get-started/install"
    exit 1
  fi
  
  # Check if web platform is enabled
  if ! flutter config --list | grep -q "enable-web: true"; then
    log_warn "Web platform not enabled. Enabling now..."
    flutter config --enable-web
  fi
  
  log_success "Flutter setup verified: $(flutter --version | head -1)"
}

# Clean previous builds
clean_build() {
  log_info "Cleaning previous builds..."
  cd "$PROJECT_DIR"
  flutter clean
  log_success "Clean complete"
}

# Get dependencies
get_dependencies() {
  log_info "Getting dependencies..."
  cd "$PROJECT_DIR"
  flutter pub get
  log_success "Dependencies updated"
}

# Build web version
build_web() {
  log_info "Building Flutter web version (this may take 2-5 minutes)..."
  cd "$PROJECT_DIR"
  flutter build web --release
  
  if [ -d "$BUILD_DIR" ]; then
    log_success "Build complete: $BUILD_DIR"
  else
    log_error "Build failed: $BUILD_DIR not found"
    exit 1
  fi
}

# Deploy to remote server
deploy_to_server() {
  local server=$1
  local server_path=${2:-/var/www/gps-tracker-admin}
  
  log_info "Deploying to $server:$server_path"
  
  if ! command -v scp &> /dev/null; then
    log_error "scp command not found. Cannot deploy."
    echo "Manual deployment: Copy $BUILD_DIR/* to server:$server_path"
    return 1
  fi
  
  log_info "Uploading files..."
  scp -r "$BUILD_DIR"/* "$server:$server_path/" || {
    log_error "Upload failed"
    return 1
  }
  
  log_info "Restarting nginx..."
  ssh "$server" "sudo systemctl restart nginx" || {
    log_warn "Could not restart nginx remotely. SSH manually and run: sudo systemctl restart nginx"
    return 1
  }
  
  log_success "Deployment complete"
  echo "Access dashboard at: http://$(echo $server | cut -d'@' -f2 | cut -d':' -f1)/"
}

# Main execution
main() {
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  Admin Dashboard Build & Deploy Tool   ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}\n"
  
  # Parse arguments
  local deploy_server=""
  local deploy_path="/var/www/gps-tracker-admin"
  
  case "${1:-}" in
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --help, -h              Show this help message"
      echo "  --web                   Build web version only"
      echo "  --deploy SERVER         Deploy to remote server (e.g., user@host.com or user@host.com:port)"
      echo "  --path PATH             Deployment path on server (default: /var/www/gps-tracker-admin)"
      echo ""
      echo "Examples:"
      echo "  $0 --web                                    # Just build web"
      echo "  $0 --deploy admin@gps-server.com            # Build and deploy to server"
      echo "  $0 --deploy admin@gps-server.com --path /opt/dashboard  # Custom path"
      exit 0
      ;;
    --web)
      ;;
    --deploy)
      deploy_server="$2"
      if [ -z "$deploy_server" ]; then
        log_error "No server specified for --deploy"
        exit 1
      fi
      shift 2
      
      # Check for custom path
      if [ -n "${1:-}" ] && [ "$1" = "--path" ]; then
        deploy_path="$2"
        shift 2
      fi
      ;;
    "")
      # Default: build web only
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
  
  # Execute build process
  check_flutter
  clean_build
  get_dependencies
  build_web
  
  # Deploy if requested
  if [ -n "$deploy_server" ]; then
    deploy_to_server "$deploy_server" "$deploy_path"
  else
    log_info "Build complete. To deploy, run:"
    echo "  $0 --deploy user@server.com"
  fi
  
  echo ""
  log_success "All done!"
}

# Run main function
main "$@"
