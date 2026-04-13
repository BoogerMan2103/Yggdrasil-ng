# build_android.ps1 — Build yggdrasil-mobile as an Android shared library
# for all ABIs and generate UniFFI Kotlin bindings.
#
# Prerequisites (run once):
#   rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
#   cargo install cargo-ndk
#   Install Android NDK via Android Studio -> SDK Manager -> NDK (Side by side)
#
# Usage:
#   .\scripts\build_android.ps1

param(
    [string]$NdkVersion = "",          # Override NDK version (auto-detected if empty)
    [string]$ApiLevel = "24",          # Minimum Android API level
    [switch]$Debug = $false            # Build debug instead of release
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot | Split-Path    # crate root (parent of scripts/)
$WorkspaceRoot = $Root | Split-Path | Split-Path  # workspace root

# ── Auto-detect NDK ──────────────────────────────────────────────────────────

$SdkRoot = $env:ANDROID_HOME
if (-not $SdkRoot) {
    $SdkRoot = "$env:LOCALAPPDATA\Android\Sdk"
}

$NdkRoot = $env:ANDROID_NDK_HOME
if (-not $NdkRoot) {
    $NdkDir = Join-Path $SdkRoot "ndk"
    if ($NdkVersion) {
        $NdkRoot = Join-Path $NdkDir $NdkVersion
    } else {
        $installed = Get-ChildItem $NdkDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($installed) {
            $NdkRoot = $installed.FullName
        }
    }
}

if (-not $NdkRoot -or -not (Test-Path $NdkRoot)) {
    Write-Error "Android NDK not found. Set ANDROID_NDK_HOME or install via Android Studio SDK Manager."
}
Write-Host "Using NDK: $NdkRoot"
$env:ANDROID_NDK_HOME = $NdkRoot

# ── Targets ──────────────────────────────────────────────────────────────────

$Targets = @(
    @{ Triple = "aarch64-linux-android";   Abi = "arm64-v8a"    },
    @{ Triple = "armv7-linux-androideabi"; Abi = "armeabi-v7a"  },
    @{ Triple = "i686-linux-android";     Abi = "x86"          },
    @{ Triple = "x86_64-linux-android";   Abi = "x86_64"       }
)

$OutRoot = Join-Path $Root "jniLibs"

# ── Build all ABIs ────────────────────────────────────────────────────────────

foreach ($t in $Targets) {
    Write-Host ""
    Write-Host "=== Building for $($t.Triple) ===" -ForegroundColor Cyan

    $jniDir = Join-Path $OutRoot $t.Abi
    New-Item -ItemType Directory -Force $jniDir | Out-Null

    $args = @(
        "ndk",
        "--target", $t.Triple,
        "--platform", $ApiLevel,
        "-o", $OutRoot,
        "build",
        "--package", "yggdrasil-mobile"
    )
    if (-not $Debug) { $args += "--release" }

    Push-Location $WorkspaceRoot
    try {
        & cargo @args
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Build failed for $($t.Triple)"
        }
    } finally {
        Pop-Location
    }

    Write-Host "Built: $jniDir\libyggdrasil_mobile.so" -ForegroundColor Green
}

# ── Remove dependency .so files ──────────────────────────────────────────────

foreach ($t in $Targets) {
    $jniDir = Join-Path $OutRoot $t.Abi
    Get-ChildItem $jniDir -Filter "*.so" |
        Where-Object { $_.Name -ne "libyggdrasil_mobile.so" } |
        ForEach-Object {
            Write-Host "  Removing $($_.Name) from $($t.Abi)" -ForegroundColor DarkGray
            Remove-Item $_.FullName -Force
        }
}

# ── Generate Kotlin bindings ──────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Generating UniFFI Kotlin bindings ===" -ForegroundColor Cyan

# Build the native Windows DLL first so uniffi-bindgen can read its metadata.
Write-Host "Building native Windows DLL for binding generation..."
Push-Location $WorkspaceRoot
try {
    & cargo build -p yggdrasil-mobile --lib
    if ($LASTEXITCODE -ne 0) { Write-Error "Native lib build failed" }
} finally {
    Pop-Location
}

$RefLib = Join-Path $WorkspaceRoot "target\debug\yggdrasil_mobile.dll"
if (-not (Test-Path $RefLib)) {
    Write-Error "Native DLL not found: $RefLib"
}

$BindingsDir = Join-Path $Root "kotlin-bindings"
New-Item -ItemType Directory -Force $BindingsDir | Out-Null

Push-Location $WorkspaceRoot
try {
    & cargo run --bin uniffi-bindgen -- generate `
        --library $RefLib `
        --language kotlin `
        --out-dir $BindingsDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "uniffi-bindgen failed"
    }
} finally {
    Pop-Location
}

# ── Copy to Android project ───────────────────────────────────────────────────

$AndroidProject = "E:\Projects\Android\yggdrasil-android-ng"
$AndroidJniDest = Join-Path $AndroidProject "app\src\main\jniLibs"

Write-Host ""
Write-Host "=== Copying to Android project ===" -ForegroundColor Cyan

# Copy jniLibs
if (Test-Path (Split-Path $AndroidJniDest)) {
    New-Item -ItemType Directory -Force $AndroidJniDest | Out-Null
    Copy-Item -Path "$OutRoot\*" -Destination $AndroidJniDest -Recurse -Force
    Write-Host "JNI libs copied to: $AndroidJniDest" -ForegroundColor Green
} else {
    Write-Warning "Android project not found, skipping jniLibs copy: $AndroidProject"
}

# Copy Kotlin bindings
$KotlinSrc = Get-ChildItem $BindingsDir -Recurse -Filter "*.kt" | Select-Object -First 1
if ($KotlinSrc) {
    $KotlinDest = Join-Path $AndroidProject "app\src\main\java\uniffi\yggdrasil_mobile"
    New-Item -ItemType Directory -Force $KotlinDest | Out-Null
    Copy-Item $KotlinSrc.FullName -Destination $KotlinDest -Force
    Write-Host "Kotlin bindings copied to: $KotlinDest" -ForegroundColor Green
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
Write-Host "JNI libraries:"
foreach ($t in $Targets) {
    $so = Join-Path $OutRoot "$($t.Abi)\libyggdrasil_mobile.so"
    if (Test-Path $so) {
        $size = (Get-Item $so).Length / 1MB
        Write-Host "  $so  ($([math]::Round($size, 1)) MB)"
    }
}
Write-Host ""
Write-Host "Kotlin bindings:"
Get-ChildItem $BindingsDir -Recurse -Filter "*.kt" | ForEach-Object {
    Write-Host "  $($_.FullName)"
}
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Ensure 'implementation ""net.java.dev.jna:jna:5.18.1@aar""' is in app/build.gradle"
Write-Host "  2. Build the Android app: ./gradlew assembleRelease"
