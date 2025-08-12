# Simple AWS Deployment

Deploy AWS EC2 instances with a single command using Docker. Clean, simple, works everywhere.

## 🚀 Quick Start

### 1. Setup AWS Credentials (One-time)

.\setup-credentials.ps1   # Windows (PowerShell)
./setup-credentials.sh    # Mac/Linux/WSL

### 2. Deploy Your Application

.\docker-deploy.ps1       # Windows (PowerShell)
./docker-deploy.sh        # Mac/Linux/WSL

#### Examples

.\docker-deploy.ps1                                 # Deploy with defaults (generic Linux server) - Windows
./docker-deploy.sh                                  # Deploy with defaults (generic Linux server) - Mac/Linux/WSL

.\docker-deploy.ps1 -Config config/erlang.yml       # Deploy Erlang (generic server) - Windows
./docker-deploy.sh -c config/erlang.yml             # Deploy Erlang (generic server) - Mac/Linux/WSL

.\docker-deploy.ps1 -Config config/dxnn.yml         # Deploy DXNN/Erlang application - Windows
./docker-deploy.sh -c config/dxnn.yml               # Deploy DXNN/Erlang application - Mac/Linux/WSL

.\docker-deploy.ps1 -Config config/nodejs.yml       # Deploy Node.js application - Windows
./docker-deploy.sh -c config/nodejs.yml             # Deploy Node.js application - Mac/Linux/WSL

.\docker-deploy.ps1 -Cleanup                        # Clean up when done - Windows
./docker-deploy.sh -x                               # Clean up when done - Mac/Linux/WSL

That's it! 🎉

## View 
    tail -f /var/log/cloud-init-output.log
    control - c   ## exit
    tmux attach -t trader
    contrl - b + d  ## exit


## 📜 What You Get

- EC2 Instance - Configured for your app type
- SSH Access - Private key automatically generated
- Security Group - Properly configured ports
- Instance Info - Displayed in terminal after deployment

## 🛠️ Available Commands

.\docker-deploy.ps1                                 # Deploy with default config - Windows
./docker-deploy.sh                                  # Deploy with default config - Mac/Linux/WSL

.\docker-deploy.ps1 -Config config/dxnn.yml         # Deploy with specific config - Windows
./docker-deploy.sh -c config/dxnn.yml               # Deploy with specific config - Mac/Linux/WSL


.\docker-deploy.ps1 -Shell                          # Interactive shell for debugging - Windows
./docker-deploy.sh -s                               # Interactive shell for debugging - Mac/Linux/WSL

.\docker-deploy.ps1 -Cleanup                        # Clean up all AWS resources - Windows
./docker-deploy.sh -x                               # Clean up all AWS resources - Mac/Linux/WSL

.\docker-deploy.ps1 -Build                          # Rebuild Docker image - Windows
./docker-deploy.sh -b                               # Rebuild Docker image - Mac/Linux/WSL

.\docker-deploy.ps1 -Help                           # Show help - Windows
./docker-deploy.sh -h                               # Show help - Mac/Linux/WSL

## 📁 Configuration Files

Available in config/:

- generic.yml - Basic Linux development server
- erlang.yml - Generic Erlang/OTP development environment
- dxnn.yml - DXNN/Erlang neural networks
- nodejs.yml - Node.js applications
- dxnn-test.yml - Optimized for your DXNN project

## 🔧 Requirements

- Docker Desktop - For containerized deployment
- AWS Account - With programmatic access
- PowerShell - For Windows (included in Windows 10+)
- Mac/Linux Terminal or WSL - For Unix-based systems or WSL on Windows
- AWS CLI - Installed and configured (aws configure)

## 🐛 Troubleshooting

### Docker Issues

docker --version                      # Check Docker status  
docker info                           # Check Docker info  

.\docker-deploy.ps1 -Build            # Rebuild image - Windows  
./docker-deploy.sh -b                 # Rebuild image - Mac/Linux/WSL  

### AWS Issues

aws sts get-caller-identity           # Check credentials  

.\setup-credentials.ps1               # Recreate credentials - Windows  
./setup-credentials.sh                # Recreate credentials - Mac/Linux/WSL  

### SSH Issues

ssh -i your-key.pem ec2-user@PUBLIC_IP   # Manual SSH connection  


## 📁 Project Structure

AWS-Deployment/  
├── config/                 # Configuration templates  
│   ├── dxnn.yml           # DXNN/Erlang deployment  
│   ├── generic.yml        # Generic Linux server  
│   ├── nodejs.yml         # Node.js application  
│   └── dxnn-test.yml      # Your DXNN project optimized  
├── scripts/               # Utility scripts  
│   ├── validate.sh        # AWS setup validation  
│   └── vscode-ssh.sh      # VSCode SSH config generator  
├── deploy.sh              # Core deployment logic (called by docker-deploy.sh)  
├── Dockerfile             # Container definition  
├── docker-deploy.sh       # Main deployment wrapper for Mac/Linux/WSL  
├── setup-credentials.sh   # AWS credentials setup for Mac/Linux/WSL  
├── docker-deploy.ps1      # Windows PowerShell wrapper  
└── setup-credentials.ps1  # AWS credentials setup for Windows  

## 🧹 Cleanup

To remove all AWS resources created by this tool:

.\docker-deploy.ps1 -Cleanup   # Windows  
./docker-deploy.sh -x          # Mac/Linux/WSL  

⚠️ Warning: This will terminate ALL instances created by AWS-Deployment!

---

Simple. Clean. Works. Cross-Platform. 🌟
