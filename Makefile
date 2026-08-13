SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:

INSTALLER := $(CURDIR)/bin/install.sh
CERT_DOMAIN ?=

.PHONY: install apply maps aliases cert check restart reload help

install:
	@CERT_DOMAIN="$(CERT_DOMAIN)" $(INSTALLER)

apply:
	@$(INSTALLER) --apply

maps:
	@$(INSTALLER) --maps

aliases:
	@newaliases
	@systemctl reload postfix.service

cert:
	@CERT_DOMAIN="$(CERT_DOMAIN)" $(INSTALLER) --cert

check:
	@$(INSTALLER) --check

restart:
	@$(INSTALLER) --restart

reload:
	@postfix check
	@systemctl reload postfix.service

help:
	@printf '%s\n' \
		'make install  - install and configure the complete mail stack' \
		'make apply    - copy etc-postfix/ into /etc/postfix, rebuild maps and reload' \
		'make maps     - rebuild configured Postfix hash maps' \
		'make aliases  - rebuild aliases and reload Postfix' \
		'make cert     - deploy externally managed Lets Encrypt certificates to Courier' \
		'make check    - validate Postfix, services, SASL socket and listening ports' \
		'make restart  - restart installed mail services and run checks' \
		'make reload   - validate and reload Postfix'
