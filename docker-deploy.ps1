# Simple AWS Deployment via Docker
# Deploy AWS EC2 instances with one command

param(
    [string]$Config = "config/generic.yml",
    [switch]$Build,
    [switch]$Shell,
    [switch]$Cleanup,
    [switch]$Help
)

# Colors for output
function Write-Info($message) { Write-Host "[INFO] $message" -ForegroundColor Blue }
function Write-Success($message) { Write-Host "[SUCCESS] $message" -ForegroundColor Green }
function Write-Warning($message) { Write-Host "[WARNING] $message" -ForegroundColor Yellow }
function Write-Error($message) { Write-Host "[ERROR] $message" -ForegroundColor Red }

# Show help
if ($Help) {
    Write-Host "Simple AWS Deployment" -ForegroundColor Blue
    Write-Host "====================" -ForegroundColor Blue
    Write-Host ""
    Write-Host "USAGE:" -ForegroundColor Yellow
    Write-Host "    .\docker-deploy.ps1 [-Config file] [-Build] [-Shell] [-Cleanup] [-Help]"
    Write-Host ""
    Write-Host "OPTIONS:" -ForegroundColor Yellow
    Write-Host "    -Config FILE     Configuration file (default: config/generic.yml)"
    Write-Host "    -Build           Rebuild Docker image"
    Write-Host "    -Shell           Open interactive shell"
    Write-Host "    -Cleanup         Clean up all AWS resources"
    Write-Host "    -Help            Show this help"
    Write-Host ""
    Write-Host "EXAMPLES:" -ForegroundColor Yellow
    Write-Host "    .\docker-deploy.ps1                        # Deploy with defaults"
    Write-Host "    .\docker-deploy.ps1 -Config config/dxnn.yml  # Deploy DXNN"
    Write-Host "    .\docker-deploy.ps1 -Cleanup                # Clean up resources"
    Write-Host ""
    exit 0
}

Write-Host "Simple AWS Deployment" -ForegroundColor Blue
Write-Host "====================" -ForegroundColor Blue

# Check if Docker is available
Write-Info "Checking Docker availability..."
try {
    $dockerVersion = docker --version 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed" }
    Write-Success "Docker found: $dockerVersion"
} catch {
    Write-Error "Docker not found or not running!"
    Write-Warning "Please install Docker Desktop: https://www.docker.com/products/docker-desktop"
    exit 1
}

# Check if Docker daemon is running
try {
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker daemon not running" }
    Write-Success "Docker daemon is running"
} catch {
    Write-Error "Docker daemon not running! Please start Docker Desktop."
    exit 1
}

# Build Docker image if requested or doesn't exist
if ($Build -or -not (docker image inspect aws-deployment:latest 2>$null)) {
    Write-Info "Building AWS-Deployment Docker image..."
    docker build -t aws-deployment:latest .
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to build Docker image"
        exit 1
    }
    Write-Success "Docker image built successfully"
}

# Create output directory if it doesn't exist
if (-not (Test-Path "output")) {
    New-Item -ItemType Directory -Path "output" -Force | Out-Null
}

# Prepare Docker run arguments with proper Windows path handling
$currentPath = (Get-Location).Path.Replace('\', '/')
if ($currentPath.StartsWith('C:')) {
    $currentPath = '/c' + $currentPath.Substring(2)
}

$dockerRunArgs = @(
    'run', '--rm', '-it'
    '-v', "${currentPath}:/aws-deployment"
    '-v', "${currentPath}/output:/aws-deployment/output"
)

# Add environment variables from .env file if it exists
if (Test-Path ".env") {
    Write-Info "Loading environment variables from .env file..."
    $dockerRunArgs += '--env-file', '.env'
} else {
    Write-Warning "No .env file found. Run .\setup-credentials.ps1 first."
    exit 1
}

# Handle special operations
if ($Shell) {
    Write-Info "Opening interactive shell in AWS-Deployment container..."
    & docker @dockerRunArgs 'aws-deployment:latest' '/bin/bash'
    exit $LASTEXITCODE
}

if ($Cleanup) {
    Write-Info "Cleaning up AWS resources..."
    & docker @dockerRunArgs 'aws-deployment:latest' '--cleanup'
    exit $LASTEXITCODE
}

# Execute the deployment
Write-Info "Running AWS deployment..."
& docker @dockerRunArgs 'aws-deployment:latest' '-c' $Config

$exitCode = $LASTEXITCODE
if ($exitCode -eq 0) {
    Write-Success "Operation completed successfully!"
} else {
    Write-Error "Operation failed with exit code: $exitCode"
}

exit $exitCode
