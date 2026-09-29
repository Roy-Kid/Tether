//! Live probe of Arrhenius through Tether's russh dial, not OpenSSH.
//!
//! Ignored in CI. Run:
//! `cargo test -p tether-core --test arrhenius_live -- --ignored --nocapture`

use std::sync::Arc;

use tether_core::ssh::{Challenge, Endpoint, HostKey, HostVerifier, Prompter, Verdict};
use tether_core::{Credential, Dial};

struct Trust;
#[async_trait::async_trait]
impl HostVerifier for Trust {
    async fn verify(&self, endpoint: &Endpoint, key: &HostKey) -> Verdict {
        eprintln!("trust {} {} {}", endpoint, key.algorithm, key.fingerprint);
        Verdict::Trusted
    }
}

struct LogThenDecline;
#[async_trait::async_trait]
impl Prompter for LogThenDecline {
    async fn answer(&self, challenge: &Challenge) -> Option<Vec<String>> {
        eprintln!("kbd-int name={:?} instruction={:?}", challenge.name, challenge.instruction);
        for prompt in &challenge.prompts {
            eprintln!("  echo={} text={:?}", prompt.echo, prompt.text);
        }
        None
    }
}

#[tokio::test]
#[ignore]
async fn key_then_verification_code() {
    let pem = std::fs::read_to_string(
        std::path::Path::new(&std::env::var("HOME").unwrap()).join(".ssh/id_arrhenius_mac"),
    )
    .expect("id_arrhenius_mac");

    let error = Dial::new(Endpoint::new("login.hpc.arrhenius.naiss.se", 22), "jicli594")
        .verifier(Arc::new(Trust))
        .connect(vec![
            Credential::PrivateKey { pem, passphrase: None, unlock: None },
            Credential::Interactive(Arc::new(LogThenDecline)),
        ])
        .await
        .expect_err("declining the code must not authenticate");

    eprintln!("result: {error}");
}
