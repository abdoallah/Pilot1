# CI and deployment

CI restores and builds Release, verifies the EF model has a migration, runs unit and SQL Server functional tests, validates the deployment scripts, and builds the IIS package and Linux Docker image. Test results and release artifacts are kept for 14 days. A failed test or image build prevents deployment.

Both IIS and Docker deploy automatically after a successful **push to main** CI run. Deployments use that run's artifacts and commit, without rebuilding on the production machine. PR runs cannot supply deployment artifacts. Older automatic releases are skipped when main has advanced. Each target has its own deployment concurrency group; running deployments are not cancelled by newer runs.

## One-time GitHub and server configuration

Create GitHub environments `production-iis` and `production-docker`. Restrict their deployment branches to `main`. Add required reviewers if your release process needs them. Require CI on pull requests in the main branch protection rule. These settings must be configured in GitHub; workflow files cannot enforce repository settings.

Use a Windows x64 self-hosted runner with the custom label `iis` for IIS, and a Windows x64 runner connected to a Linux Docker daemon with label `docker-linux` for Docker. A single runner may have both labels. Install the .NET 10 hosting bundle on the IIS server. Keep the runner installation outside the checkout, and keep its account restricted to the deployment resources it needs.

Environment secrets:

| Secret | Purpose |
| --- | --- |
| `APP_CONNECTION_STRING` | Runtime SQL connection using an application account, not `sa`; required for each target. Docker uses a server hostname reachable on `databases_default`, such as `sqlserver,1433`. |
| `MIGRATION_CONNECTION_STRING` | Separate SQL account allowed to change the schema; required only when automatic migrations are enabled. |

Passwords previously stored in appsettings have been removed from the working tree. They remain in Git history. Rotate any credentials that have been used with a real database, update the environment secrets, and revoke the old credentials. Do not put the replacement values in source control.

Environment variables:

| Environment | Variable | Value |
| --- | --- | --- |
| Both | `APPLY_DATABASE_MIGRATIONS` | Leave unset or `false` until the existing database is baselined. Set `true` afterward to apply forward migrations. |
| IIS | `IIS_SITE_NAME` | Existing IIS website name. |
| IIS | `IIS_APP_POOL` | Dedicated app pool for that website. |
| IIS | `IIS_RELEASES_PATH` | Absolute directory outside the current site and runner workspace, e.g. `D:\Sites\CoPilot\releases`. |
| IIS | `DATA_PROTECTION_KEYS_PATH` | Persistent directory outside release folders, e.g. `D:\Sites\CoPilot\keys`. |
| IIS | `HEALTH_URL` | Direct URL to this site's `/health`, with the correct binding and scheme; it must return HTTP 200 with `Healthy`, without redirects. |
| Docker | `DOCKER_PORT` | Host port mapped to container port 8080. |

For IIS, provision directory ACLs before the first deployment: the runner needs write access to releases; the app pool needs read/execute on releases and modify access to the keys directory. Restrict access to releases because their generated `web.config` contains the runtime connection string. Data Protection keys use Windows DPAPI; enable Load User Profile on the dedicated app pool and retain its identity/profile across releases. Ensure the IIS site is started.

For Docker, create the external network `databases_default` and connect SQL Server and the OpenTelemetry collector to it. The app runs as the image's non-root user. The named volume `copilot-data-protection` retains authentication keys across container replacements; restrict host access to it and back it up. Container replacement during the first deployment with persistent keys can invalidate tokens issued by older deployments.

## Existing database: preserve data before enabling migrations

The existing database was created without EF migration history. **Do not delete it or run the development initializer against it.** Deployment does not call that initializer. Automatic migrations are disabled by default, and the application does not apply migrations at startup.

1. Take a verified database backup and test the migration adoption on a restored copy.
2. Download `migrations.sql` from the successful CI run's `iis-release` artifact. Compare the existing schema against `20260926185921_InitialCreate`, including Identity tables, columns, nullability, indexes, keys and constraints. Resolve differences explicitly without deleting user data.
3. Once the schema is confirmed equivalent, have the database administrator create EF's `__EFMigrationsHistory` table (using the definition in `migrations.sql`) and record migration `20260926185921_InitialCreate` with product version `10.0.5`. Do not execute the initial migration's CREATE TABLE statements over an existing schema, or record the baseline before checking schema equivalence.
4. Test the migration bundle against the restored copy and confirm data and application behavior are preserved. Configure the migration secret, then set `APPLY_DATABASE_MIGRATIONS=true` for the environment.

For a new empty database, the bundle can apply the initial migration directly. For future model changes:

```powershell
dotnet tool restore
dotnet ef migrations add DescribeTheChange --project src/Infrastructure --startup-project src/Web --output-dir Data/Migrations
```

Review generated migrations before committing. Both deployment targets may share a database; use backward-compatible schema changes because the old app can still be serving requests during migration. Bundles use EF's migration lock. Application rollback does not undo database migrations. Keep schema cleanup/removal for a later release after all old app versions are retired.

## Health checks and rollback

Docker starts a candidate on a loopback-only temporary port and checks `/health` before stopping the current container. It then switches to the configured port and checks health again. On failure it restores the previous container. Successful releases retain the prior container and image for recovery.

IIS publishes into a new release directory, stops the app pool with a bounded wait, changes the site's physical path, restarts it and checks `/health`. A failed activation or health check restores the previous physical path. Existing release files are retained rather than overwritten or recursively deleted.

For a manual redeployment or rollback, run the appropriate CD workflow from `main` and supply the **successful CI push run ID** for the desired commit. Its artifact must still exist and must contain these deployment scripts. This intentionally permits an older commit. Do not roll back an application to a version incompatible with the current database schema. Export artifacts for longer-term retention if required.

Clean up old release folders, stopped previous containers, and unused images according to a retention policy after verifying they are no longer needed. Keep Data Protection volumes and database backups independent of that cleanup.

## Local development and validation

To run against an existing local database without deleting or migrating its data, use the `local` profile:

```powershell
dotnet run --project src/Web --launch-profile local
```

Open `http://localhost:5217/swagger`; readiness is at `http://localhost:5217/health`. This profile sets both environment names to `Local` and reads `src/Web/appsettings.Local.json` through the standard ASP.NET Core configuration loader. Put `ConnectionStrings:CoPilotDb` in that file, plus an optional `DataProtection:KeysPath`. The file is ignored by Git and excluded from publish output, so it stays on this machine. GitHub Environment secrets are separate and do not supply local settings.

For example, the local file has this shape (replace the example values with your own):

```json
{
  "ConnectionStrings": {
    "CoPilotDb": "Server=localhost;Database=CoPilotDb;User Id=...;Password=...;TrustServerCertificate=True"
  },
  "DataProtection": {
    "KeysPath": "C:\\path\\to\\local-keys"
  }
}
```

Use Aspire (`dotnet run --project src/AppHost`) for locally provisioned dependencies, or set `ConnectionStrings__CoPilotDb` in your shell/secret store when running the web project directly. Never point the Development environment at a database containing data to retain: its template initializer deletes and recreates the database.

```powershell
dotnet build CoPilot.slnx -c Release
dotnet test CoPilot.slnx -c Release --no-build --no-restore
./scripts/deploy/Validate-Scripts.ps1
./scripts/deploy/Test-DeploymentHelpers.ps1
```

Functional tests need Docker with Linux containers and use a separate SQL Server container. They run with the `Testing` environment, apply real migrations, and verify that reapplying migrations preserves data.
