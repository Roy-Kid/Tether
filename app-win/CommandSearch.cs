namespace TetherApp;

public static class CommandSearch
{
    public static bool Matches(string query, string text) => query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
        .All(word => text.Contains(word, StringComparison.OrdinalIgnoreCase));
}
