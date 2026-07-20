# Security policy

Winix crosses a sensitive boundary: it plans and applies user and machine configuration, and system placement can run with administrator privileges. Treat unexpected elevation, execution of an unintended binary or plugin, plan/apply mismatch, unplanned mutation, download-integrity failure, and leakage of configuration or event data as security-relevant.

## Supported versions

Winix is currently pre-1.0. Security fixes are made on `main` and, after binary releases begin, on the latest published release. Older commits and superseded pre-1.0 releases are not maintained separately.

| Version | Supported |
| --- | --- |
| `main` | Yes |
| Latest published release | Yes, once releases begin |
| Older commits or releases | No |

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, discussion, pull request, configuration file, or event log.

Use the repository's **Security** tab to open a private vulnerability report through GitHub Security Advisories. If the reporting button is unavailable, contact the repository owner through their GitHub profile and request a private reporting channel before sending technical details.

Include, when safe to do so:

- the affected commit or version and Windows edition/build;
- the placement and privilege level involved;
- minimal reproduction steps and the expected versus observed operation queue;
- whether mutation occurred before a failure;
- relevant sanitized output; and
- a suggested remediation, if known.

Remove usernames, machine names, access tokens, package credentials, local paths, configuration secrets, and other personal data. The maintainers will coordinate validation, remediation, and disclosure through the private report.

For ordinary correctness problems with no confidential or exploit-relevant details, use the public [issue tracker](https://github.com/ibuildthecloud/winix/issues).
