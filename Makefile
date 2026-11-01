SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:
.DEFAULT_GOAL := help

INSTALLER := $(CURDIR)/bin/install.sh
IMPORTER := $(CURDIR)/examples/migrations/import-postfix-server.sh
CERT_DOMAIN ?=
REMOTE ?=
MIGRATION_NAME ?= postfix-import

.PHONY: install install-server install-relay apply maps aliases cert check status restart reload purge reset import-fetch import-users import-mail import-config test help

install:
	@CERT_DOMAIN="$(CERT_DOMAIN)" bash $(INSTALLER)

install-server:
	@POSTFIXER_ROLE_HINT=inout CERT_DOMAIN="$(CERT_DOMAIN)" bash $(INSTALLER)

install-relay:
	@POSTFIXER_ROLE_HINT=relay CERT_DOMAIN="$(CERT_DOMAIN)" bash $(INSTALLER)

apply:
	@bash $(INSTALLER) --apply

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

import-fetch:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-fetch REMOTE=root@mail.example.com\n' >&2; exit 64; }
	@REMOTE="$(REMOTE)" MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --fetch

import-users:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-users REMOTE=root@mail.example.com\n' >&2; exit 64; }
	@REMOTE="$(REMOTE)" MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --fetch-maildir-users

import-mail:
	@test -n "$(REMOTE)" || { printf 'Usage: make import-mail REMOTE=root@mail.example.com\n' >&2; exit 64; }
	@REMOTE="$(REMOTE)" MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --fetch-maildirs

import-config:
	@MIGRATION_NAME="$(MIGRATION_NAME)" bash $(IMPORTER) --install-modular

test:
	@bash tests/profile-install-test.sh

help:
	@printf '%s\n' \
		'make                 - show this help' \
		'sudo make install-server - install a Maildir/Courier user server' \
		'sudo make install-relay  - install a relay without IMAP/POP' \
		'sudo make install        - choose the role interactively' \
		'make apply    - reapply shared and node-specific configuration' \
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
		'make import-mail REMOTE=root@host  - rsync user Maildirs into secure staging' \
		'make import-config - install safe staged map files under /etc/postfix' \
		'make test     - run local installer profile tests'
