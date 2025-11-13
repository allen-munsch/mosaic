# 🎨 Mosaic - Quick Start Guide

## 🚨 Fixing Your Current Docker Error

The error you're seeing happens because Docker is trying to copy files that don't exist yet. Here's how to fix it:

### Option 1: Use the Setup Script (Recommended)

```bash
# Make setup script executable
chmod +x setup.sh

# Run setup - creates all necessary files
./setup.sh

# Now Docker will work
docker-compose up
```

### Option 2: Manual Setup

```bash
# Create directory structure
mkdir -p lib/mosaic config priv

# Copy the provided files
cp lib/mosaic/application.ex lib/mosaic/application.ex
cp config/config.exs config/config.exs
cp config/dev.exs config/dev.exs
cp config/prod.exs config/prod.exs
cp mix.exs.fixed mix.exs

# Create empty mix.lock
touch mix.lock

# Now Docker will work
docker-compose up
```

### Option 3: Use Simplified Docker Compose (Fastest)

If you just want to see it running:

```bash
# Use the simple version (no Elixir build required)
docker-compose -f docker-compose.simple.yml up
```

This runs a placeholder coordinator that just responds to health checks.

## 📁 Required Project Structure

Before running `docker-compose up`, you need:

```
mosaic/
├── mix.exs                  # ← Must exist
├── mix.lock                 # ← Can be empty file
├── lib/
│   └── mosaic/
│       └── application.ex   # ← Must exist
├── config/
│   ├── config.exs           # ← Must exist
│   ├── dev.exs              # ← Must exist
│   └── prod.exs             # ← Must exist
├── priv/                    # ← Can be empty directory
├── docker-compose.yml
├── Dockerfile
└── nginx.conf
```

## 🛠️ Step-by-Step Setup

### 1. Initialize Project

```bash
# Create a new directory
mkdir mosaic-search
cd mosaic-search

# Extract all provided files here
# Then run:
chmod +x setup.sh deploy.sh
./setup.sh
```

### 2. Verify Files

```bash
# Check that required files exist
ls -la lib/mosaic/application.ex
ls -la config/config.exs
ls -la mix.exs

# All should show files, not errors
```

### 3. Test Locally (Without Docker)

```bash
# Install Elixir dependencies
mix deps.get

# Start the server
mix run --no-halt

# In another terminal, test it
curl http://localhost:4040/health
# Should return: healthy

curl http://localhost:4040/api/status
# Should return JSON with status info
```

### 4. Build Docker Image

```bash
# Build the image
docker-compose build coordinator

# This should work now that files exist
```

### 5. Start Full Stack

```bash
# Start all services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f coordinator

# Test the API
curl http://localhost/health
```

## 🐛 Troubleshooting

### Error: "not found: /priv"

**Problem:** Docker can't find the priv directory

**Solution:**
```bash
mkdir -p priv
touch priv/.gitkeep
```

### Error: "not found: mix.lock"

**Problem:** mix.lock file doesn't exist

**Solution:**
```bash
touch mix.lock
```

### Error: "failed to compute cache key"

**Problem:** Required files don't exist

**Solution:** Run the setup script:
```bash
./setup.sh
```

### Services Start But Coordinator Fails

**Check logs:**
```bash
docker-compose logs coordinator
```

**Common issue:** Port already in use
```bash
# Check what's using port 4040
sudo lsof -i :4040

# Kill it or change PORT in docker-compose.yml
```

## 📦 What Each File Does

| File | Purpose |
|------|---------|
| `setup.sh` | Creates all required files and directories |
| `mix.exs` | Elixir project configuration |
| `lib/mosaic/application.ex` | Main application code |
| `config/*.exs` | Application configuration |
| `Dockerfile` | Instructions to build the container |
| `docker-compose.yml` | Multi-service orchestration |
| `nginx.conf` | Load balancer configuration |

## 🎯 Quick Verification

After setup, verify everything works:

```bash
# 1. Local development
mix deps.get && mix run --no-halt &
curl http://localhost:4040/health
kill %1

# 2. Docker
docker-compose build
docker-compose up -d
curl http://localhost/health

# 3. Full stack
docker-compose ps
# All services should show "Up" or "Up (healthy)"
```

## 🚀 Next Steps

Once everything is running:

1. **Access Grafana**: http://localhost:3000 (admin/admin)
2. **Check Prometheus**: http://localhost:9090
3. **API Docs**: See ARCHITECTURE.md
4. **Start Building**: Add your search logic to `lib/mosaic/`

## 📚 Additional Resources

- **Full Documentation**: See README.md
- **Architecture**: See ARCHITECTURE.md
- **Deployment**: See DEPLOYMENT_GUIDE.md
- **Branding**: See BRANDING.md

## 💡 Pro Tips

1. **Use Makefile**: `make help` shows all available commands
2. **Check logs**: `make logs` follows all service logs
3. **Quick restart**: `make restart`
4. **Health check**: `make health`

## 🆘 Still Having Issues?

```bash
# Clean everything and start fresh
docker-compose down -v
rm -rf _build deps
./setup.sh
docker-compose up --build
```

If that doesn't work, you can use the simplified version:
```bash
docker-compose -f docker-compose.simple.yml up
```

This runs without building the Elixir app - great for testing the infrastructure.

---

**Need Help?** Check the error messages carefully - they usually tell you exactly which file is missing!
