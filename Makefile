SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:
.DEFAULT_GOAL := help

INSTALLER := $(CURDIR)/bin/install.sh
IMPORTER := $(CURDIR)/examples/migrations/import-postfix-server.sh
CERT_DOMAIN ?=
REMOTE ?=
REMOTE_HOME_ROOT ?= /home
MIGRATION_NAME ?= postfix-import
POSTFIXER_INSTALL_MAILMAN ?= auto
IMPORT_MAILMAN ?= no

.PHONY: install install-server install-relay apply sync maps aliases cert check status restart reload purge reset backup backup-config backup-mail import-fetch import-users import-auth import-mail import-mail-final import-config import-legacy-submission test help

install:
	@POSTFIXER_INSTALL_MAILMAN="$(POSTFIXER_INSTALL_MAILMAN)" MAILMAN_DOMAIN="$(MAILMAN_DOMAIN)" MAILMAN_OWNER="$(MAILMAN_OWNER)" CERT_DOMAIN="$(CERT_DOMAIN)" bash $(INSTALLER)

install-server:
	@POSTFIXER_ROLE_HINT=inout POSTFIXER_INSTALL_MAILMAN="$(POSTFIXER_INSTALL_MAILMAN)" MAILMAN_DOMAIN="$(MAILMAN_DOMAIN)" MAILMAN_OWNER="$(MAILMAN_OWNER)" CERT_DOMAIN="$(CERT_DOMAIN)" bash $(INSTALLER)

install-relay:
	@POSTFIXER_ROLE_HINT=relay POSTFIXER_INSTALL_MAILMAN="$(POSTFIXER_INSTALL_MAILMAN)" MAILMAN_DOMAIN="$(MAILMAN_DOMAIN)" MAILMAN_OWNER="$(MAILMAN_OWNER)" CERT_DOMAIN="$(CERT_DOMAIN)" bash $(INSTALLER)

apply:
	@bash $(INSTALLER) --apply

sync: apply maps cert restart

maps:
	@bash $(INSTALLER) --maps

aliases:
	@newaliases
	@systemctl reload postfix.service

cert:
	@CERT_DOMAIN="$(CERT_DOMAIN)" bash $(INSTALLER) --cert

check:
	@bash $(INSTALLER) --check

status:
	@bash $(INSTALLER) --status

restart:
	@bash $(INSTALLER) --restart

reload:
	@postfix check
	@systemctl reload postfix.service

reset:
	@POSTFIXER_RESET_CONFIRM="$${POSTFIXER_RESET_CONFIRM:-}" bash $(CURDIR)/bin/reset.sh

purge: reset

backup:
	@bash $(CURDIR)/bin/backup.sh all

backup-config:
	@bash $(CURDIR)/bin/backup.sh config

backup-mail:
	@bash $(CURDIR)/bin/backup.sh maildirs

import-fetch:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-fetch REMOTE=root@mail.example.com\n' >&2; exit 64; }
	@REMOTE="$(REMOTE)" MIGRATION_NAME="$(MIGRATION_NAME)" IMPORT_MAILMAN="$(IMPORT_MAILMAN)" bash $(IMPORTER) --fetch

import-users:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-users REMOTE=root@mail.example.com\n' >&2; exit 64; }
	@REMOTE="$(REMOTE)" REMOTE_HOME_ROOT="$(REMOTE_HOME_ROOT)" MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --fetch-maildir-users

import-auth:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-auth REMOTE=root@mail.example.com ACCOUNT_AUTH_CONFIRM=reviewed\n' >&2; exit 64; }
	@MIGRATION_NAME="$(MIGRATION_NAME)" ACCOUNT_AUTH_CONFIRM="$(ACCOUNT_AUTH_CONFIRM)" bash $(IMPORTER) --install-account-auth

import-mail:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-mail REMOTE=root@mail.example.com\n' >&2; exit 64; }
	@REMOTE="$(REMOTE)" REMOTE_HOME_ROOT="$(REMOTE_HOME_ROOT)" MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --fetch-maildirs

import-mail-final:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-mail-final REMOTE=root@mail.example.com FINAL_SYNC_CONFIRM=source-frozen\n' >&2; exit 64; }
	@REMOTE="$(REMOTE)" REMOTE_HOME_ROOT="$(REMOTE_HOME_ROOT)" MIGRATION_NAME="$(MIGRATION_NAME)" FINAL_SYNC_CONFIRM="$(FINAL_SYNC_CONFIRM)" bash $(IMPORTER) --fetch-maildirs-final

import-config:
	@MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --install-modular

import-legacy-submission:
	@LEGACY_SUBMISSION_CONFIRM="$${LEGACY_SUBMISSION_CONFIRM:-}" bash $(IMPORTER) --configure-legacy-submission

test:
	@bash tests/postgrey-test.sh
	@bash tests/profile-install-test.sh
	@python3 -m unittest discover -s tests -p 'test_mailman3.py'

.PHONY: install-mailman3 check-mailman3 test-mailman3
install-mailman3:
	@MAILMAN_DOMAIN="$(MAILMAN_DOMAIN)" MAILMAN_OWNER="$(MAILMAN_OWNER)" CERT_DOMAIN="$(CERT_DOMAIN)" python3 bin/mailman3.py install

check-mailman3:
	@python3 bin/mailman3.py check

test-mailman3:
	@python3 -m unittest discover -s tests -p 'test_mailman3.py'

.PHONY: import-mailman3-fetch
import-mailman3-fetch:
	@REMOTE="$(REMOTE)" MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --fetch-mailman

.PHONY: import-mailman3-plan import-mailman3
import-mailman3-plan:
	@MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --plan-mailman

import-mailman3:
	@MIGRATION_NAME="$(MIGRATION_NAME)" MAILMAN_LIST="$(MAILMAN_LIST)" MAILMAN_TARGET_DOMAIN="$(MAILMAN_TARGET_DOMAIN)" MAILMAN_IMPORT_CONFIRM="$(MAILMAN_IMPORT_CONFIRM)" MAILMAN_SOURCE_FROZEN="$(MAILMAN_SOURCE_FROZEN)" bash $(IMPORTER) --import-mailman

help:
	@printf '%s\n' \
		'make                 - show this help' \
		'sudo make install-server - install a Maildir/Courier user server' \
		'sudo make install-relay  - install a relay without IMAP/POP' \
		'sudo make install        - choose the role interactively' \
		'make apply    - reapply shared and node-specific configuration' \
		'make sync     - apply config, rebuild maps, sync certs, restart and check' \
		'make maps     - rebuild configured Postfix hash maps' \
		'make aliases  - rebuild aliases and reload Postfix' \
		'make cert     - deploy externally managed Lets Encrypt certificates' \
		'make check    - validate Postfix, services, SASL, TLS and submission' \
		'make status   - show the configured role and service state' \
		'make restart  - restart installed mail services and run checks' \
		'make reload   - validate and reload Postfix' \
		'make purge    - purge mail stack after explicit confirmation' \
		'make import-fetch REMOTE=root@host - stage remote Postfix configuration' \
		'make import-users REMOTE=root@host - stage Maildir account records' \
		'make import-auth REMOTE=root@host ACCOUNT_AUTH_CONFIRM=reviewed - install reviewed shadow hashes' \
		'make import-mail REMOTE=root@host - pre-sync Maildirs without deleting staged files' \
		'make import-mail-final REMOTE=root@host FINAL_SYNC_CONFIRM=source-frozen - final exact sync after source shutdown' \
		'make import-config - install safe staged map files under /etc/postfix' \
		'make test     - run local installer profile and Mailman tests' \
		'make install-mailman3 MAILMAN_DOMAIN=lists.example.net MAILMAN_OWNER=postmaster@example.net CERT_DOMAIN=example.net - opt-in Mailman Suite' \
		'make check-mailman3 - check list services and HTTPS' \
		'make import-mailman3-fetch REMOTE=root@old-ip - stage legacy list data without importing' \
		'make import-mailman3-plan MIGRATION_NAME=name - inventory list configs and archives without executing pickle' \
		'make import-mailman3 MAILMAN_LIST=list MAILMAN_IMPORT_CONFIRM=reviewed MAILMAN_SOURCE_FROZEN=yes - import held/private'
