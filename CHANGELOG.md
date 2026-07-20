## 1.0.6


* **FIXES**: 

- Dynamic iOS Development Team: Added support for reading client-specific DEVELOPMENT_TEAM IDs from environment variables during iOS builds.
- Centralized Structured Logging: Replaced ad-hoc print() statements with a dedicated Logger class (phase, info, success, warning, error) to produce clean, scannable terminal output.
- Enhanced Exception Tracking: Replaced generic throws with contextual BuildException instances that include actionable remediation suggestions (fix) to easily pinpoint and resolve    failure root causes.
- Built-in default ignore rules to prevent accidental copying of sensitive files such as:
  - `service_account.json`
  - `*.pem`, `*.key`, `*.p12`, `*.jks`, `*.keystore`
- Resilient Pipeline Execution: Improved file I/O checks, pre-flight configuration validation, and build step notifications across all commands.
- Support for user-defined ignore patterns via `.udaraignore` file.
