# Security Policy

**English** | [简体中文](SECURITY.zh-CN.md)

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

Please report security vulnerabilities privately via [GitHub Security Advisories](https://github.com/SemouSky/ip-allowlist/security/advisories/new).

Do not open public issues for security vulnerabilities.

## Threat Model

### Assets Protected
- Firewall rule integrity (allow-list correctness)
- System availability (no accidental lockout)
- Configuration confidentiality (no secret leakage)
- Fail2ban ignoreip integrity

### Threat Actors
- **Network attackers**: Spoofed IP ranges, malicious source content
- **Local attackers**: Compromised source files, config tampering
- **Supply chain**: Malicious releases, compromised dependencies

### Attack Vectors & Mitigations

| Vector | Mitigation |
|--------|------------|
| Malicious IP ranges from source | `min_entries`, `max_shrink_ratio` validation; per-source canonicalization |
| Config injection | Strict key=value parser (no eval); input validation |
| Path traversal | Absolute path resolution; no spaces in paths |
| Temp file races | `mktemp` with secure permissions; atomic rename |
| Privilege escalation | Runs as root only for firewall/fail2ban ops; minimal capabilities |
| Rollback failure | Pre-apply snapshots; in-progress marker for crash recovery |
| Supply chain | Release-please automation; signed releases; verified install script |

### Trust Boundaries

```
Internet (untrusted) → HTTP fetch → Validation → Firewall (trusted)
                                         ↓
                              Fail2ban drop-in (trusted)
```

- Network sources: Untrusted, validated before use
- Local file sources: Trusted if config is trusted
- Config files: Trusted (root-owned, 0640)
- State directory: Trusted (root-owned, 0700)

## Security Practices

### Input Validation
- All IPs validated as valid CIDR (IPv4/IPv6)
- CIDR canonicalization (merge overlapping, sort)
- Source `min_entries` prevents empty allow-lists
- Source `max_shrink_ratio` alerts on drastic reductions

### Safe Operations
- No `eval`, no dynamic code execution
- `mktemp` for all temporary files
- `flock` for config/state locking
- Atomic `mv` for all writes
- Fixed User-Agent: `ip-allowlist/<version>`

### Least Privilege
- Script runs as root (required for firewall)
- Config/state: root:root, 0640/0700
- Log file: root:root, 0640
- Systemd: `ProtectSystem=strict`, `ReadWritePaths` limited

### Audit Trail
- Structured logging (JSON optional)
- Run ID per execution
- State snapshots with timestamps
- All firewall changes logged

## Hardening Recommendations

1. **Restrict config access**: `chmod 640 /etc/ip-allowlist/config.conf`
2. **Monitor logs**: Alert on `ERROR` level or shrink ratio warnings
3. **Pin versions**: Use specific release tarballs, not `main` branch
4. **Verify downloads**: Check release signatures when available
5. **Test changes**: Use `ip-allowlist check` before `sync`

## Known Limitations

- No TLS certificate pinning for HTTP sources
- No GPG verification of source content
- Single User-Agent (fingerprintable)
- Requires root for firewall operations

## Future Improvements

- [ ] Certificate pinning for HTTP sources
- [ ] GPG-signed source verification
- [ ] Capability-based sandboxing
- [ ] SELinux/AppArmor profiles