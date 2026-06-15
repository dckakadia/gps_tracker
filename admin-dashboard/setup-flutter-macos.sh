#!/bin/bash

# Flutter Setup Guide for macOS - Quick Reference

echo "🔍 Checking Flutter installation..."
echo ""

# Check if Flutter is already installed
if command -v flutter &> /dev/null; then
    echo "✅ Flutter is already installed!"
    echo ""
    flutter --version
    exit 0
fi

echo "❌ Flutter not found. Installing now..."
echo ""
echo "This will download and install Flutter SDK (~500MB)"
echo "It may take 5-10 minutes depending on your internet connection"
echo ""

# Install Flutter via Homebrew
echo "📦 Installing Flutter via Homebrew..."
brew install flutter

# Verify installation
if command -v flutter &> /dev/null; then
    echo ""
    echo "✅ Flutter installed successfully!"
    echo ""
    flutter --version
    echo ""
    echo "📝 Setting up Flutter web support..."
    flutter config --enable-web
    echo ""
    echo "🎉 Flutter is ready to use!"
    echo ""
    echo "Next steps:"
    echo "  cd admin-dashboard"
    echo "  flutter pub get"
    echo "  flutter build web --release"
else
    echo ""
    echo "❌ Installation failed. Try manual installation:"
    echo "   https://flutter.dev/docs/get-started/install/macos"
    exit 1
fi
