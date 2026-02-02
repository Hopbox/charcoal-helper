## [1.2.6] - 2026-01-31

### Added
- Periodic timeout check for in-flight queries (WAN failure protection)
- Enhanced SIGTERM handler that drains pending queries gracefully
- Production monitoring script (charcoal-stats.sh)

### Fixed
- Connection timeout now uses configurable value from UCI/config
- Division by zero in stats script on systems without GNU awk

### Changed
- Socket linger timeout: 0s → 2s for graceful server shutdown
- Version bumped to 1.2.6

### Notes
- This release is production-ready with comprehensive failure protection
- Tested on OpenWrt 18.06+ with MT7621, ar71xx, and x86 platforms
