#!/bin/bash

# Setup script to install git hooks for the leveraged vault protocol
# Run this after cloning the repository to enable pre-push checks

set -e

echo "🔧 Setting up git hooks..."

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    echo "❌ Error: Not in a git repository root directory"
    exit 1
fi

# Copy hooks to .git/hooks directory
echo "📋 Installing pre-push hook..."
cp scripts/hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push

echo "✅ Git hooks installed successfully!"
echo "💡 The pre-push hook will now run forge fmt, build, and test checks before each push"
echo "   This prevents pipeline failures by catching issues locally"