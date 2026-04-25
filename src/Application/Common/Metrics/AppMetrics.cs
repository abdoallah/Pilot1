using System.Diagnostics.Metrics;

namespace CoPilot.Application.Common.Metrics;

public sealed class AppMetrics
{
    private readonly Counter<long> _todoItemsCreated;
    private readonly Counter<long> _todoItemsCompleted;
    private readonly Counter<long> _todoListsCreated;

    public AppMetrics(IMeterFactory meterFactory)
    {
        var meter = meterFactory.Create("CoPilot.Application");
        _todoItemsCreated  = meter.CreateCounter<long>("copilot.todoitems.created",  description: "Total todo items created");
        _todoItemsCompleted = meter.CreateCounter<long>("copilot.todoitems.completed", description: "Total todo items completed");
        _todoListsCreated  = meter.CreateCounter<long>("copilot.todolists.created",  description: "Total todo lists created");
    }

    public void RecordTodoItemCreated()   => _todoItemsCreated.Add(1);
    public void RecordTodoItemCompleted() => _todoItemsCompleted.Add(1);
    public void RecordTodoListCreated()   => _todoListsCreated.Add(1);
}
