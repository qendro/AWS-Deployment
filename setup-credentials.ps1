# AWS Credentials Setup Script (PowerShell)
# This script helps you set up AWS credentials for the deployment system

function Write-Info($message) { Write-Host "[INFO] $message" -ForegroundColor Blue }
function Write-Success($message) { Write-Host "[SUCCESS] $message" -ForegroundColor Green }
function Write-Warning($message) { Write-Host "[WARNING] $message" -ForegroundColor Yellow }
function Write-Error($message) { Write-Host "[ERROR] $message" -ForegroundColor Red }

Write-Host "AWS Credentials Setup" -ForegroundColor Blue
Write-Host "=====================" -ForegroundColor Blue
Write-Host ""

# Check if .env already exists
if (Test-Path ".env") {
    Write-Warning "Found existing .env file"
    $overwrite = Read-Host "Do you want to overwrite it? (y/N)"
    if ($overwrite -ne "y" -and $overwrite -ne "Y") {
        Write-Info "Keeping existing .env file"
        exit 0
    }
}

Write-Info "Creating .env file for AWS credentials..."
Write-Host ""
$accessKey = Read-Host "Enter your AWS Access Key ID"
$secretKey = Read-Host "Enter your AWS Secret Access Key" -AsSecureString
$secretKeyPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretKey))
$region = Read-Host "Enter your default AWS region [us-east-1]"
if ([string]::IsNullOrEmpty($region)) { $region = "us-east-1" }

$envContent = @"
# AWS Credentials for AWS-Deployment
# Generated on $(Get-Date)

AWS_ACCESS_KEY_ID=$accessKey
AWS_SECRET_ACCESS_KEY=$secretKeyPlain
AWS_DEFAULT_REGION=$region
"@

$envContent | Out-File -FilePath ".env" -Encoding utf8
Write-Success ".env file created successfully!"
Write-Info "Your credentials are stored in .env"

Write-Host ""
Write-Info "Testing AWS credentials..."
try {
    $identity = aws sts get-caller-identity --output json | ConvertFrom-Json
    Write-Success "AWS credentials are working!"
    Write-Info "Connected as: $($identity.Arn)"
    Write-Info "Account: $($identity.Account)"
} catch {
    Write-Warning "Could not verify credentials with AWS"
    Write-Info "This might be due to network issues or invalid credentials"
}

Write-Host ""
Write-Success "Setup completed!"
Write-Info "You can now run deployments with:"
Write-Info "  .\docker-deploy.ps1"
Write-Info "  .\docker-deploy.ps1 -Config config/dxnn.yml"
