FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY Directory.Build.props Directory.Packages.props global.json NuGet.Config ./
COPY .config/dotnet-tools.json .config/
COPY src/Domain/Domain.csproj src/Domain/
COPY src/Shared/Shared.csproj src/Shared/
COPY src/Application/Application.csproj src/Application/
COPY src/Infrastructure/Infrastructure.csproj src/Infrastructure/
COPY src/ServiceDefaults/ServiceDefaults.csproj src/ServiceDefaults/
COPY src/Web/Web.csproj src/Web/

RUN dotnet restore src/Web/Web.csproj

COPY src/ src/

RUN dotnet publish src/Web/Web.csproj -c Release -o /app/publish --no-restore --no-self-contained
RUN dotnet tool restore && dotnet ef migrations bundle --project src/Infrastructure --startup-project src/Web --configuration Release --target-runtime linux-x64 --output /app/efbundle

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
ARG REVISION=local
LABEL org.opencontainers.image.revision=$REVISION
WORKDIR /app
COPY --from=build /app/publish .
COPY --from=build /app/efbundle ./efbundle
RUN mkdir -p /var/lib/copilot/keys && chown "$APP_UID" /var/lib/copilot/keys
ENV DataProtection__KeysPath=/var/lib/copilot/keys
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "CoPilot.Web.dll"]
