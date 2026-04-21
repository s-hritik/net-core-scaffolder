# .NET Scaffolding Master v5.0 — Setup & Usage Guide

## What's new in v5.0

| Area | Change |
|---|---|
| Error handling | `set -e` removed. Every command uses `run()` / `must_run()` — no more false crashes |
| Rollback | Granular stack: rollback only the current phase, or everything |
| Architecture | Modular: `lib/` + `options/` — each concern in its own file |
| State | CTX associative array replaces 15 scattered globals |
| Testing | Each lib file has its own test suite; fully isolated, no real `dotnet` needed |

---

## File structure

```
scaffold/
├── scaffold.sh              ← Entry point (run this)
├── lib/
│   ├── core.sh              ← Logging · run() · atomic_write · rollback stack · CTX
│   ├── program_cs.sh        ← All Program.cs injection (Roslyn + awk fallback)
│   ├── packages.sh          ← NuGet · dotnet local tool management
│   └── project.sh           ← Project discovery · .env · DB validation
├── options/
│   ├── opt_dbfirst.sh       ← Option 1: DB-First
│   ├── opt_crud.sh          ← Options 2/3/4/7: Web API · MVC · Razor · Blazor
│   ├── opt_identity.sh      ← Option 5: Identity
│   └── opt_partialview.sh   ← Option 6: Partial View
└── tests/
    ├── test_runner.sh       ← Assert helpers + reporting
    ├── test_core.sh         ← Tests for lib/core.sh
    ├── test_program_cs.sh   ← Tests for lib/program_cs.sh
    ├── test_project.sh      ← Tests for lib/project.sh
    └── run_all.sh           ← Run all test suites
```

---

## Prerequisites

### 1. bash 5.x (required — macOS ships with bash 3.2)

```bash
# Install bash 5 via Homebrew
brew install bash

# Add to allowed shells
sudo bash -c 'echo /opt/homebrew/bin/bash >> /etc/shells'

# Make it your default shell (optional)
chsh -s /opt/homebrew/bin/bash

# Verify
bash --version   # should show 5.x
```

### 2. .NET SDK 8 or 9

```bash
# Download from https://dotnet.microsoft.com/download
dotnet --version   # should show 8.x or 9.x
```

### 3. Docker Desktop (for SQL Server on Mac)

```bash
# Download from https://www.docker.com/products/docker-desktop

# Start SQL Server container (run once, restart with: docker start sqlserver)
docker run \
  -e "ACCEPT_EULA=Y" \
  -e "MSSQL_SA_PASSWORD=Test@1234!" \
  -p 1433:1433 \
  --name sqlserver \
  -d mcr.microsoft.com/mssql/server:2022-latest

# Verify it's running
docker ps | grep sqlserver
```

---

## Installation

### Option A — Use from any .NET project (recommended)

```bash
# 1. Copy the entire scaffold/ folder to a permanent location
cp -r scaffold/ ~/tools/scaffold/

# 2. Make scaffold.sh executable
chmod +x ~/tools/scaffold/scaffold.sh
chmod +x ~/tools/scaffold/lib/*.sh
chmod +x ~/tools/scaffold/options/*.sh
chmod +x ~/tools/scaffold/tests/*.sh

# 3. Create a global alias
# Add to ~/.zshrc or ~/.bashrc:
alias scaffold='/opt/homebrew/bin/bash ~/tools/scaffold/scaffold.sh'

# Reload shell
source ~/.zshrc

# 4. Test the alias
scaffold --help
```

### Option B — Per-project (copy into project)

```bash
# Copy scaffold/ folder into your .NET project root
# Then run from that directory:
bash scaffold/scaffold.sh
```

---

## First run walkthrough

```bash
# Navigate to your .NET project (must contain a .csproj)
cd ~/Desktop/MyProject/MyProject

# Always do a dry-run first — shows exactly what will happen, touches nothing
scaffold --dry-run

# Then run for real
scaffold
```

**First-run prompts:**
```
Select Database Provider:
  1) SQL Server
  2) PostgreSQL
  3) SQLite
Provider [1-3, default: 1]: 1

  Database Name: MyAppDb
  Database User [sa]: sa
  Database Password: ••••••••
```

This creates a `.env` file with your connection string. `.env` is automatically added to `.gitignore`.

---

## Running from a solution root

If you have a solution `.sln` with multiple projects:

```
MySolution/
├── MySolution.sln
├── MySolution.Api/         ← scaffold will ask which project
├── MySolution.Core/
└── scaffold/               ← put scaffold here
```

```bash
cd ~/Desktop/MySolution
scaffold --dry-run
# → Multiple projects found in solution:
#     1) /Users/you/Desktop/MySolution/MySolution.Api/MySolution.Api.csproj
#     2) /Users/you/Desktop/MySolution/MySolution.Core/MySolution.Core.csproj
#   Select project to scaffold [1-2]: 1
```

---

## Menu options

```
1) DB-First          Reverse-engineer existing DB → Models + DbContext
2) Web API           Full CRUD API Controllers (+ optional AutoMapper DTOs)
3) MVC               Full CRUD Controllers + 5 Razor Views per model
4) Razor Pages       Full CRUD Razor Pages (Index/Create/Edit/Delete/Details)
5) Identity          Complete Auth UI + Program.cs fully wired
6) Partial View      Empty or @model-typed partial view
7) Blazor            Full CRUD Blazor pages (.NET 9+ only)
8) Exit
```

---

## Recommended test order for a new project

Run these in sequence — each test builds on the previous:

```bash
# 0. Dry-run first — always
scaffold --dry-run      # → choose 2, y, y, Product

# 1. Web API + AutoMapper  (sets up .env, DbContext, packages)
scaffold                # → 2 → y → TestBankContext → y → Product

# 2. MVC  (reuses existing context)
scaffold                # → 3 → y → select TestBankContext → Customer

# 3. Razor Pages
scaffold                # → 4 → y → select TestBankContext → Order

# 4. Partial View (empty)
scaffold                # → 6 → _ProductCard → (blank) → (blank)

# 5. Partial View (typed)
scaffold                # → 6 → _CustomerSummary → Customer → (blank)

# 6. Identity
scaffold                # → 5 → ApplicationDbContext → 0 (ALL)

# 7. DB-First (run AFTER migrations exist)
dotnet ef migrations add InitialCreate
dotnet ef database update
scaffold                # → 1 → ReverseContext

# 8. Error recovery test
# Add invalid text to Program.cs, run scaffold, confirm rollback works
```

---

## Running the tests

```bash
# Run all test suites
bash ~/tools/scaffold/tests/run_all.sh

# Run a specific suite
bash ~/tools/scaffold/tests/test_core.sh
bash ~/tools/scaffold/tests/test_program_cs.sh
bash ~/tools/scaffold/tests/test_project.sh
```

Expected output:
```
╔══════════════════════════════════════════════╗
║  scaffold.sh — Complete Test Suite           ║
╚══════════════════════════════════════════════╝
✓  test_core.sh                          18 passed
✓  test_program_cs.sh                    31 passed
✓  test_project.sh                       22 passed

  Total: 71  |  Passed: 71  |  Failed: 0  |  Score: 100%
```

Tests are fully isolated — each creates its own temp directory and cleans up after itself. No real `dotnet`, no network, no database needed.

---

## How the error handling works

```bash
# run()     — execute, log warning on failure, return exit code
# must_run() — execute, rollback everything and exit on failure
# safe_run() — execute, swallow any failure silently (for cleanup)

run      "Restore packages"  dotnet restore   # failure = warning, continues
must_run "Build project"     dotnet build     # failure = rollback + exit 1
safe_run "Shutdown server"   dotnet build-server shutdown  # always succeeds
```

When `must_run` fails it:
1. Logs the exact line and command that failed
2. Restores `appsettings.json` to its pre-scaffold state
3. Rolls back all tracked file changes (Program.cs, new context files, etc.)
4. Exits with code 1

---

## How Program.cs injection works

The script injects code using either:
- **Roslyn** (preferred): parses `Program.cs` as a real C# syntax tree via `dotnet-script`. Completely immune to IDE formatting, extra spaces, or line-breaks.
- **awk fallback**: uses forgiving regex when `dotnet-script` is unavailable.

**Stack-push mechanic** — `inject_after_builder` inserts each line immediately *after* `CreateBuilder`, pushing previous lines down. So calls are made in **reverse** of the desired final order:

```bash
# Desired final order in Program.cs:
#   Env.Load();           ← must be first
#   var connString = ...; ← must be second
#   AddDbContext(...);    ← must be third

# Call order (reversed because each pushes the previous down):
pcs_inject_after_builder ... "AddDbContext"   # injected 1st → ends up 3rd ✓
pcs_inject_after_builder ... "connString"     # injected 2nd → ends up 2nd ✓
pcs_inject_after_builder ... "Env.Load();"   # injected 3rd → ends up 1st ✓
```

---

## Troubleshooting

| Error | Fix |
|---|---|
| `bash 4.3+ required` | `brew install bash` then use `/opt/homebrew/bin/bash scaffold.sh` |
| `No .csproj found` | Run from inside a project folder or solution root |
| `Could not install dotnet-aspnet-codegenerator` | Run manually: `dotnet tool install dotnet-aspnet-codegenerator --version 8.0` |
| `Cannot reach database` | Ensure Docker is running: `docker start sqlserver` |
| `Build FAILED` after scaffold | The script auto-rolls back. Check the error, fix `Program.cs` manually, re-run |
| `Blazor requires .NET 9+` | Use option 3 (MVC) or 4 (Razor Pages) for .NET 8 projects |
