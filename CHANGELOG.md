## 1.0.5


* **FIXES**: 

- Introduced `.udaraignore` support for safer asset and secret management during whitelabel builds.
- Automatic generation of `.udaraignore` during project setup if it does not already exist.
- Built-in default ignore rules to prevent accidental copying of sensitive files such as:
  - `service_account.json`
  - `*.pem`, `*.key`, `*.p12`, `*.jks`, `*.keystore`
- Support for user-defined ignore patterns via `.udaraignore` file.
