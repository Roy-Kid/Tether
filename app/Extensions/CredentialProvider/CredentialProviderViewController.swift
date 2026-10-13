import AuthenticationServices

/// Provides nothing. A password manager offers to export to an app only when
/// the app carries a credential provider that says it takes Credential
/// Exchange, so this is what puts Tether in that list. The export itself
/// arrives at the app (`CredentialImport`), never here.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    decline()
  }

  override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
    decline()
  }

  private func decline() {
    extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain,
      code: ASExtensionError.Code.userCanceled.rawValue))
  }
}
