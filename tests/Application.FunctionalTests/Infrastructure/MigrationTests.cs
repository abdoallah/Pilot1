using CoPilot.Domain.Entities;
using CoPilot.Infrastructure.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace CoPilot.Application.FunctionalTests.Infrastructure;

public class MigrationTests : TestBase
{
    [Test]
    public async Task ApplyingMigrationsAgainPreservesExistingData()
    {
        var list = new TodoList { Title = "Preserve this list" };
        await TestApp.AddAsync(list);

        await using var scope = FunctionalTestSetup.ScopeFactory.CreateAsyncScope();
        var context = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
        await context.Database.MigrateAsync();

        (await context.Database.GetPendingMigrationsAsync()).ShouldBeEmpty();
        (await context.TodoLists.SingleAsync(x => x.Id == list.Id)).Title.ShouldBe(list.Title);
    }
}
