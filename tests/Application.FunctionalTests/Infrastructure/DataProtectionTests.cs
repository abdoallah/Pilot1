using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace CoPilot.Application.FunctionalTests.Infrastructure;

public class DataProtectionTests
{
    [Test]
    public void ProtectedDataSurvivesApplicationHostReplacement()
    {
        var directory = Path.Combine(Path.GetTempPath(), "copilot-keys-tests", Guid.NewGuid().ToString("N"));
        try
        {
            string protectedValue;
            using (var firstHost = CreateHost(directory))
            {
                protectedValue = firstHost.Services.GetRequiredService<IDataProtectionProvider>()
                    .CreateProtector("DeploymentPersistenceTest")
                    .Protect("existing-session");
            }

            using var replacementHost = CreateHost(directory);
            var restoredValue = replacementHost.Services.GetRequiredService<IDataProtectionProvider>()
                .CreateProtector("DeploymentPersistenceTest")
                .Unprotect(protectedValue);
            restoredValue.ShouldBe("existing-session");
        }
        finally
        {
            if (Directory.Exists(directory)) { Directory.Delete(directory, recursive: true); }
        }
    }

    private static IHost CreateHost(string directory)
    {
        var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings { EnvironmentName = "Testing" });
        builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["DataProtection:KeysPath"] = directory
        });
        builder.AddWebServices();
        return builder.Build();
    }
}
