# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial project structure based on postgresql-ha-ec2 v2.0
- Multi-region DR architecture design
- Cross-region streaming replication configuration
- pgBackRest backup with S3 cross-region replication

### Changed
- Project name from "postgresql-ha-ec2" to "postgresql-ha-dr"
- Updated terraform locals for v3.0

### Planned
- DR region infrastructure (Terraform modules)
- Automated failover procedures
- DR testing and validation scripts
- Monitoring and alerting for DR scenarios
- Documentation for DR operations

## [3.0.0] - TBD

Initial release of PostgreSQL HA with Disaster Recovery.

---

## Previous Versions

For changes in previous versions, see:
- [postgresql-ha-ec2 CHANGELOG](https://github.com/jeansouto/postgresql-ha-ec2/blob/main/CHANGELOG.md) (v2.0)
