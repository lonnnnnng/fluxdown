use serde::{Deserialize, Serialize};
use thiserror::Error;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
const KEYRING_SERVICE: &str = "FluxDown";
const MAX_CREDENTIAL_REF_LENGTH: usize = 128;

/// 运行时从系统凭据库取出的认证信息；该结构不会写入队列 JSON。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredCredential {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CredentialStoreError {
    #[error("凭据引用不能为空或过长")]
    InvalidReference,
    #[error("当前平台没有可用的系统凭据库")]
    UnsupportedPlatform,
    #[error("无法访问系统凭据库")]
    Backend,
    #[error("系统凭据内容格式无效")]
    InvalidPayload,
}

/// 规范化队列中保存的凭据引用；只保存引用本身，不保存用户名或密码。
pub fn normalize_credential_ref(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty() && trimmed.len() <= MAX_CREDENTIAL_REF_LENGTH)
            .then(|| trimmed.to_string())
    })
}

pub fn validate_credential_ref(value: &str) -> Result<String, CredentialStoreError> {
    let normalized = normalize_credential_ref(Some(value.to_string()))
        .ok_or(CredentialStoreError::InvalidReference)?;
    Ok(normalized)
}

pub fn set_credential(
    reference: &str,
    username: &str,
    password: &str,
) -> Result<(), CredentialStoreError> {
    let reference = validate_credential_ref(reference)?;
    if username.trim().is_empty() {
        return Err(CredentialStoreError::InvalidPayload);
    }
    let payload = serde_json::to_string(&StoredCredential {
        username: username.to_string(),
        password: password.to_string(),
    })
    .map_err(|_| CredentialStoreError::InvalidPayload)?;

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &reference)
            .map_err(|_| CredentialStoreError::Backend)?;
        entry
            .set_password(&payload)
            .map_err(|_| CredentialStoreError::Backend)
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let _ = (reference, payload);
        Err(CredentialStoreError::UnsupportedPlatform)
    }
}

pub fn get_credential(reference: &str) -> Result<StoredCredential, CredentialStoreError> {
    let reference = validate_credential_ref(reference)?;

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &reference)
            .map_err(|_| CredentialStoreError::Backend)?;
        let payload = entry
            .get_password()
            .map_err(|_| CredentialStoreError::Backend)?;
        serde_json::from_str(&payload).map_err(|_| CredentialStoreError::InvalidPayload)
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let _ = reference;
        Err(CredentialStoreError::UnsupportedPlatform)
    }
}

pub fn delete_credential(reference: &str) -> Result<(), CredentialStoreError> {
    let reference = validate_credential_ref(reference)?;

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &reference)
            .map_err(|_| CredentialStoreError::Backend)?;
        entry
            .delete_credential()
            .map_err(|_| CredentialStoreError::Backend)
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let _ = reference;
        Err(CredentialStoreError::UnsupportedPlatform)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_reference_normalization_does_not_store_secrets() {
        assert_eq!(
            normalize_credential_ref(Some("  office-sftp  ".to_string())),
            Some("office-sftp".to_string())
        );
        assert_eq!(normalize_credential_ref(Some("   ".to_string())), None);
        assert_eq!(
            normalize_credential_ref(Some("password".to_string())),
            Some("password".to_string())
        );
        assert_eq!(normalize_credential_ref(Some("x".repeat(129))), None);
    }

    #[test]
    fn credential_reference_validation_rejects_empty_values() {
        assert_eq!(
            validate_credential_ref("  ").unwrap_err(),
            CredentialStoreError::InvalidReference
        );
    }
}
