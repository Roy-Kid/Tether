import Testing

// These suites share AppKit's windows, pasteboard and the plugin dialog gateway.
// Serializing each child alone still lets siblings change that global state.
@Suite("browser UI", .serialized)
struct BrowserUITests {}
