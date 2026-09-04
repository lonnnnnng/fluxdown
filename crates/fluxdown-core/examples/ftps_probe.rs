use std::sync::Arc;

use tokio::io::AsyncReadExt;

use suppaftp::tokio::{AsyncRustlsConnector, AsyncRustlsFtpStream};
use suppaftp::tokio_rustls::rustls;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let host = "test.rebex.net";
    let address = "test.rebex.net:990";

    // Variant 1: default rustls builder (same as fluxdown ftps_tls_config)
    let config = rustls_client_config();
    let connector = AsyncRustlsConnector::from(tokio_rustls_connector(config));
    println!("variant 1: connect_secure_implicit with webpki roots...");
    match AsyncRustlsFtpStream::connect_secure_implicit(address, connector, host).await {
        Ok(mut ftp) => {
            let text = ftp.login("demo", "password").await?;
            println!("variant 1 OK, login: {:?}", text);
            let _ = ftp.quit().await;
        }
        Err(error) => println!("variant 1 FAIL: {error}"),
    }

    // Variant 2: no cert verification at all
    let config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(danger::NoVerifier))
        .with_no_client_auth();
    let connector = AsyncRustlsConnector::from(tokio_rustls_connector(config));
    println!("variant 2: connect_secure_implicit with no verifier...");
    match AsyncRustlsFtpStream::connect_secure_implicit(address, connector, host).await {
        Ok(mut ftp) => {
            let text = ftp.login("demo", "password").await?;
            println!("variant 2 OK, login: {:?}", text);
            let _ = ftp.quit().await;
        }
        Err(error) => println!("variant 2 FAIL: {error}"),
    }

    // Variant 3: explicit FTPS on port 21 (AUTH TLS)
    let config = rustls_client_config();
    let connector = AsyncRustlsConnector::from(tokio_rustls_connector(config));
    println!("variant 3: explicit FTPS on 21...");
    match AsyncRustlsFtpStream::connect("test.rebex.net:21").await {
        Ok(stream) => match stream.into_secure(connector, host).await {
            Ok(mut ftp) => {
                let text = ftp.login("demo", "password").await?;
                println!("variant 3 OK, login: {:?}", text);
                let _ = ftp.quit().await;
            }
            Err(error) => println!("variant 3 into_secure FAIL: {error}"),
        },
        Err(error) => println!("variant 3 connect FAIL: {error}"),
    }

    // Variant 5: create reqwest client first (mimics DownloadEngine::new), then implicit FTPS
    println!("variant 5: reqwest Client::new() then connect_secure_implicit...");
    let client = reqwest::Client::new();
    let config = rustls_client_config();
    let connector = AsyncRustlsConnector::from(tokio_rustls_connector(config));
    match AsyncRustlsFtpStream::connect_secure_implicit(address, connector, host).await {
        Ok(mut ftp) => {
            let text = ftp.login("demo", "password").await?;
            println!("variant 5 OK, login: {:?}", text);
            let _ = ftp.quit().await;
        }
        Err(error) => println!("variant 5 FAIL: {error}"),
    }
    drop(client);

    // Variant 6: full fluxdown_core DownloadEngine download of the same URL
    println!("variant 6: fluxdown_core DownloadEngine ftps download...");
    let out_dir = std::env::temp_dir().join("ftps_probe_variant6");
    let mut request = fluxdown_core::DownloadRequest::new(
        "ftps://demo:password@test.rebex.net/readme.txt".to_string(),
        out_dir.clone(),
    );
    request.file_name = Some("probe6-readme.txt".to_string());
    match fluxdown_core::DownloadEngine::new()
        .download(request)
        .await
    {
        Ok(summary) => println!(
            "variant 6 OK: bytes={} path={}",
            summary.bytes_written,
            summary.output_path.display()
        ),
        Err(error) => println!("variant 6 FAIL: {error}"),
    }
    let _ = std::fs::remove_dir_all(&out_dir);

    // Variant 8: implicit FTPS + full data-channel transfer (like real download)
    println!("variant 8: implicit FTPS full transfer of readme.txt...");
    let config = rustls_client_config();
    let connector = AsyncRustlsConnector::from(tokio_rustls_connector(config));
    match AsyncRustlsFtpStream::connect_secure_implicit(address, connector, host).await {
        Ok(mut ftp) => {
            match ftp.login("demo", "password").await {
                Ok(_) => println!("variant 8 login OK"),
                Err(error) => println!("variant 8 login FAIL: {error}"),
            }
            let mut stream = match ftp.retr_as_stream("readme.txt").await {
                Ok(stream) => {
                    println!("variant 8 retr stream OK");
                    Some(stream)
                }
                Err(error) => {
                    println!("variant 8 retr FAIL: {error}");
                    println!("(continuing to next variants)");
                    None
                }
            };
            if let Some(stream) = stream.as_mut() {
                let mut buf = Vec::new();
                match stream.read_to_end(&mut buf).await {
                    Ok(n) => println!("variant 8 read OK: {n} bytes"),
                    Err(error) => println!("variant 8 read FAIL: {error}"),
                }
            }
        }
        Err(error) => println!("variant 8 connect FAIL: {error}"),
    }

    // Variant 9: implicit FTPS with resumption disabled, full transfer
    println!("variant 9: implicit FTPS resumption-disabled full transfer...");
    let root_store = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let mut config = rustls::ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();
    let connector = AsyncRustlsConnector::from(tokio_rustls_connector(config));
    match AsyncRustlsFtpStream::connect_secure_implicit(address, connector, host).await {
        Ok(mut ftp) => {
            match ftp.login("demo", "password").await {
                Ok(_) => println!("variant 9 login OK"),
                Err(error) => println!("variant 9 login FAIL: {error}"),
            }
            let mut stream = match ftp.retr_as_stream("readme.txt").await {
                Ok(stream) => {
                    println!("variant 9 retr stream OK");
                    Some(stream)
                }
                Err(error) => {
                    println!("variant 9 retr FAIL: {error}");
                    println!("(variant 9 done)");
                    None
                }
            };
            if let Some(stream) = stream.as_mut() {
                let mut buf = Vec::new();
                match stream.read_to_end(&mut buf).await {
                    Ok(n) => println!(
                        "variant 9 read OK: {n} bytes: {:?}",
                        String::from_utf8_lossy(&buf[..40.min(n)])
                    ),
                    Err(error) => println!("variant 9 read FAIL: {error}"),
                }
            }
        }
        Err(error) => println!("variant 9 connect FAIL: {error}"),
    }

    // Variant 11: force TLS1.2 on the whole FTPS session, full transfer
    println!("variant 11: implicit FTPS forced-TLS1.2 full transfer...");
    let root_store = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = rustls::ClientConfig::builder_with_protocol_versions(&[&rustls::version::TLS12])
        .with_root_certificates(root_store)
        .with_no_client_auth();
    let connector = AsyncRustlsConnector::from(tokio_rustls_connector(config));
    match AsyncRustlsFtpStream::connect_secure_implicit(address, connector, host).await {
        Ok(mut ftp) => {
            match ftp.login("demo", "password").await {
                Ok(_) => println!("variant 11 login OK"),
                Err(error) => println!("variant 11 login FAIL: {error}"),
            }
            let mut stream = match ftp.retr_as_stream("readme.txt").await {
                Ok(stream) => {
                    println!("variant 9 retr stream OK");
                    Some(stream)
                }
                Err(error) => {
                    println!("variant 9 retr FAIL: {error}");
                    println!("(variant 9 done)");
                    None
                }
            };
            if let Some(stream) = stream.as_mut() {
                let mut buf = Vec::new();
                match stream.read_to_end(&mut buf).await {
                    Ok(n) => println!(
                        "variant 9 read OK: {n} bytes: {:?}",
                        String::from_utf8_lossy(&buf[..40.min(n)])
                    ),
                    Err(error) => println!("variant 9 read FAIL: {error}"),
                }
            }
        }
        Err(error) => println!("variant 11 connect FAIL: {error}"),
    }

    // Variant 10 removed: raw-byte inspection is done by the Python probe script.

    // Variant 4: raw tokio-rustls handshake on 990 (no suppaftp involved)
    println!("variant 4: raw tokio-rustls handshake on 990...");
    let tcp = tokio::net::TcpStream::connect(address).await?;
    let config = rustls_client_config();
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    match connector
        .connect(host.try_into().unwrap(), tcp)
        .await
    {
        Ok(mut tls) => {
            use tokio::io::AsyncReadExt;
            let mut buf = [0u8; 128];
            let n = tls.read(&mut buf).await?;
            println!("variant 4 OK, banner: {:?}", String::from_utf8_lossy(&buf[..n]));
        }
        Err(error) => println!("variant 4 FAIL: {error}"),
    }

    Ok(())
}

fn rustls_client_config() -> rustls::ClientConfig {
    let root_store = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    rustls::ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth()
}

fn tokio_rustls_connector(config: rustls::ClientConfig) -> suppaftp::tokio_rustls::TlsConnector {
    tokio_rustls::TlsConnector::from(Arc::new(config))
}

use suppaftp::tokio_rustls;

mod danger {
    use suppaftp::tokio_rustls::rustls::client::danger::{
        HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
    };
    use suppaftp::tokio_rustls::rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use suppaftp::tokio_rustls::rustls::{DigitallySignedStruct, SignatureScheme};

    #[derive(Debug)]
    pub struct NoVerifier;

    impl ServerCertVerifier for NoVerifier {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp_response: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, suppaftp::tokio_rustls::rustls::Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, suppaftp::tokio_rustls::rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, suppaftp::tokio_rustls::rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            vec![
                SignatureScheme::RSA_PKCS1_SHA256,
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::ED25519,
                SignatureScheme::RSA_PSS_SHA256,
            ]
        }
    }
}
