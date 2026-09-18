import SwiftUI
import Tether
import TetherUI

/// One tab's contents.
struct SessionView: View {
  let tab: SessionTab

  var body: some View {
    ZStack {
      Theme.terminal

      switch tab.stage {
      case .connecting:
        Status(
          spinning: true,
          title: "Connecting to \(tab.host.hostname)",
          detail: tab.host.address)

      case .asking(let question):
        QuestionPane(question: question)

      case .connected:
        terminal

      case .failed(let reason):
        Status(
          spinning: false,
          title: "Could not connect",
          detail: reason,
          tone: .danger)

      case .ended(let reason):
        Status(
          spinning: false,
          title: "Session ended",
          detail: reason ?? "The shell closed.",
          tone: reason == nil ? .neutral : .danger)
      }
    }
  }

  @ViewBuilder
  private var terminal: some View {
    if let frame = tab.frame {
      TerminalSurface(
        frame: frame,
        onInput: { tab.send($0) },
        onResize: { tab.resize(columns: $0, rows: $1) },
        onScroll: { tab.scroll($0) })
    }
  }

}

/// The states a session sits in when it is not drawing a screen.
struct Status: View {
  enum Tone { case neutral, danger }

  let spinning: Bool
  let title: String
  var detail: String?
  var tone: Tone = .neutral

  var body: some View {
    VStack(spacing: 10) {
      if spinning {
        ProgressView()
          .controlSize(.small)
          .tint(Theme.subtle)
      }

      Text(title)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(tone == .danger ? Theme.danger : Theme.text)

      if let detail {
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(Theme.subtle)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 380)
  
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Both things a handshake can stop for.
struct QuestionPane: View {
  let question: Question

  @State private var answers: [String] = []

  var body: some View {
    Group {
      switch question.kind {
      case .trust(let host, let why, let answer):
        trust(host, why, answer)
      case .prompts(let instruction, let prompts, let answer):
        ask(instruction, prompts, answer)
      }
    }
    .padding(24)
    .frame(width: 420)
    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func trust(
    _ host: HostIdentity, _ why: TrustQuestion, _ answer: @escaping (Bool) -> Void
  ) -> some View {
    // A first sighting and a key that changed are not the same event, and
    // saying "unrecognised host" for both is how the dangerous one gets
    // accepted as routine. The changed case is the reason a record is kept.
    let changed: KnownHost? = if case .changed(let from) = why { from } else { nil }

    return VStack(alignment: .leading, spacing: 14) {
      Label {
        Text(changed == nil ? "Unrecognised host" : "This host's key has changed")
      } icon: {
        Image(
          systemName: changed == nil
            ? "questionmark.circle" : "exclamationmark.triangle.fill")
      }
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(changed == nil ? Theme.text : Theme.danger)

      Text(
        changed == nil
          ? "\(host.host) offered a \(host.algorithm) key. Accept it only if the fingerprint matches what your administrator published."
          : "\(host.host) previously offered a different key. Either an administrator replaced it, or something is answering in its place. Do not accept it until you know which."
      )
      .font(.system(size: 12))
      .foregroundStyle(Theme.subtle)
      .fixedSize(horizontal: false, vertical: true)

      // The fingerprint is what a person actually compares, so it is
      // monospaced, selectable, and set apart from the prose.
      fingerprint(host.fingerprint, label: changed == nil ? nil : "Offered now")

      if let changed {
        fingerprint(changed.fingerprint, label: "Accepted before")
      }

      HStack {
        Button("Reject") { answer(false) }
          .buttonStyle(QuietButton())
        Spacer()
        Button("Trust") { answer(true) }
          .buttonStyle(FilledButton())
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func fingerprint(_ value: String, label: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label {
        Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.subtle)
      }
      Text(value)
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(2)
        .foregroundStyle(Theme.text)
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
    }
  }

  private func ask(
    _ instruction: String,
    _ prompts: [AuthPrompt],
    _ answer: @escaping ([String]) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(instruction.isEmpty ? "The server is asking" : instruction)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.text)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
        // `echo` is the server's instruction about the answer, not a
        // guess about what it is: nothing here says "password" or
        // "one-time code" unless the server did (spec §10).
        Field(
          label: prompt.text,
          text: binding(index),
          secure: !prompt.echo)
      }

      HStack {
        Button("Cancel") { answer([]) }
          .buttonStyle(QuietButton())
        Spacer()
        Button("Send") { answer(padded(to: prompts.count)) }
          .buttonStyle(FilledButton())
          .keyboardShortcut(.defaultAction)
      }
    }
    .onAppear { answers = Array(repeating: "", count: prompts.count) }
  }

  private func binding(_ index: Int) -> Binding<String> {
    Binding(
      get: { index < answers.count ? answers[index] : "" },
      set: { if index < answers.count { answers[index] = $0 } })
  }

  /// One answer per prompt, in order — the protocol requires the count to
  /// match, and a short array fails the exchange rather than the field.
  private func padded(to count: Int) -> [String] {
    var result = answers
    while result.count < count { result.append("") }
    return Array(result.prefix(count))
  }
}

/// A labelled field, in the app's own clothes rather than the platform's.
struct Field: View {
  let label: String
  @Binding var text: String
  var secure: Bool = false
  var placeholder: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.subtle)

      Group {
        if secure {
          SecureField(placeholder, text: $text)
        } else {
          TextField(placeholder, text: $text)
        }
      }
      .accessibilityLabel(label)
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .foregroundStyle(Theme.text)
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke, lineWidth: 1))
    }
  }
}

struct QuietButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(Theme.subtle)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        Theme.raised.opacity(configuration.isPressed ? 0.6 : 1),
        in: RoundedRectangle(cornerRadius: 7))

  }
}
