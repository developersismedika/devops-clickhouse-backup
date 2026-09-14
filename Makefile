SHELL := /bin/sh

.PHONY: check checksum package

check:
	sh -n clickhouse-backup.sh
	sh -n install.sh

checksum: check
	@sha256sum clickhouse-backup.sh > clickhouse-backup.sh.sha256
	@sha256sum install.sh > install.sh.sha256

package: checksum
	zip -r devops-clickhouse-backup-v$$(cat VERSION).zip \
		clickhouse-backup.sh clickhouse-backup.sh.sha256 \
		install.sh install.sh.sha256 VERSION README.md CHANGELOG.md \
		backup.env.example .gitignore Makefile tests .github
