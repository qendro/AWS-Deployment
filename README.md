# Simple AWS Deployment

Deploy AWS EC2 instances with a single command using Docker. Clean, simple, works everywhere.

## 🚀 Quick Start

### 1. Setup AWS Credentials (One-time)
```powershell
.\setup-credentials.ps1
```

### 2. Deploy Your Application
```powershell
# Deploy with defaults (generic Linux server)
.\docker-deploy.ps1

# Deploy Erlang (generic  server)
.\docker-deploy.ps1 -Config config/erlang.yml

# Deploy DXNN/Erlang application
.\docker-deploy.ps1 -Config config/dxnn.yml

# Deploy Node.js application  
.\docker-deploy.ps1 -Config config/nodejs.yml

# Clean up when done
.\docker-deploy.ps1 -Cleanup
```

That's it! 🎉

## 📋 What You Get

- **EC2 Instance** - Configured for your app type
- **SSH Access** - Private key automatically generated  
- **Security Group** - Properly configured ports
- **Instance Info** - Saved to `output/` directory

## 🛠️ Available Commands

```powershell
# Deploy with default config
.\docker-deploy.ps1

# Deploy with specific config
.\docker-deploy.ps1 -Config config/dxnn.yml

# Interactive shell for debugging
.\docker-deploy.ps1 -Shell

# Clean up all AWS resources
.\docker-deploy.ps1 -Cleanup

# Rebuild Docker image
.\docker-deploy.ps1 -Build

# Show help
.\docker-deploy.ps1 -Help
```

## 📁 Configuration Files

Available in `config/`:
- `generic.yml` - Basic Linux development server
- `erlang.yml` - Generic Erlang/OTP development environment
- `dxnn.yml` - DXNN/Erlang neural networks  
- `nodejs.yml` - Node.js applications
- `dxnn-test.yml` - Optimized for your DXNN project

## 🔧 Requirements

- **Docker Desktop** - For containerized deployment
- **AWS Account** - With programmatic access
- **PowerShell** - For Windows (included in Windows 10+)

## 🐛 Troubleshooting

### Docker Issues
```powershell
# Check Docker status
docker --version
docker info

# Rebuild image if needed
.\docker-deploy.ps1 -Build
```

### AWS Issues  
```powershell
# Check credentials
aws sts get-caller-identity

# Recreate credentials
.\setup-credentials.ps1
```

### SSH Issues
```powershell
# Find your SSH key and IP in output/ directory
dir output\

# Manual SSH connection
ssh -i output\aws-deployment-key-TIMESTAMP-key.pem ec2-user@PUBLIC_IP
```

## 📁 Project Structure

```
AWS-Deployment/
├── config/                 # Configuration templates
│   ├── dxnn.yml           # DXNN/Erlang deployment
│   ├── generic.yml        # Generic Linux server  
│   ├── nodejs.yml         # Node.js application
│   └── dxnn-test.yml      # Your DXNN project optimized
├── scripts/               # Utility scripts
│   ├── validate.sh        # AWS setup validation
│   └── vscode-ssh.sh      # VSCode SSH config generator
├── output/                # Deployment artifacts (auto-created)
│   ├── deployment-*.json  # Instance information
│   ├── *-key.pem         # SSH private keys
│   └── ssh-config-*.txt  # VSCode SSH configs
├── deploy.sh             # Core deployment logic
├── Dockerfile            # Container definition
├── docker-deploy.ps1     # Windows PowerShell wrapper
└── setup-credentials.ps1 # AWS credentials setup
```

## 🧹 Cleanup

To remove all AWS resources created by this tool:

```powershell
.\docker-deploy.ps1 -Cleanup
```

**⚠️ Warning**: This will terminate ALL instances created by AWS-Deployment!

---

**Simple. Clean. Works.** 🎯
