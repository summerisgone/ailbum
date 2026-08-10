set dotenv-load
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

root := justfile_directory()
export PYINSTALLER_CONFIG_DIR := root + "/build/pyinstaller-cache"

default:
    @just --list

# Install locked Python and Node.js dependencies.
install:
    uv sync --extra dev --locked
    npm ci --prefix "{{ root }}/desktop"

# Download the optional ONNX models embedded into release installers.
models:
    uv run ailbum download-models --models-dir "{{ root }}/desktop/models"

# Run Python tests, linting, and renderer checks.
check:
    uv run pytest
    uv run ruff check .
    npm run build --prefix "{{ root }}/desktop"

# Freeze the Python CV backend for the current operating system.
backend:
    uv run pyinstaller --noconfirm --clean --onedir --console --name ailbum-backend --paths "{{ root }}/src" --exclude-module torch --exclude-module transformers --exclude-module pytest --distpath "{{ root }}/build/backend" --workpath "{{ root }}/build/pyinstaller" --specpath "{{ root }}/build" "{{ root }}/packaging/desktop_backend.py"

# Build the Electron renderer.
desktop:
    npm run build --prefix "{{ root }}/desktop"

# Build a Windows MSI on Windows.
package-msi: backend
    npm run package:msi --prefix "{{ root }}/desktop"

# Build a macOS DMG on macOS.
package-dmg: backend
    npm run package:dmg --prefix "{{ root }}/desktop"

# Build a Debian package on Linux.
package-deb: backend
    npm run package:deb --prefix "{{ root }}/desktop"

# Build the installer appropriate for the host OS.
package-host:
    just {{ if os() == "macos" { "package-dmg" } else if os() == "windows" { "package-msi" } else { "package-deb" } }}

# Remove generated backend and installer output.
clean:
    node -e "const fs=require('node:fs'); for (const path of process.argv.slice(1)) fs.rmSync(path, {recursive:true, force:true})" "{{ root }}/build" "{{ root }}/desktop/release"
