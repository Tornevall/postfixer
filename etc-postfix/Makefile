# Postfix map maintenance for the active server configuration.
# Run as root (or through a narrowly delegated sudo rule).

POSTFIX_DIR := /etc/postfix
VIRTUAL_DIR := $(POSTFIX_DIR)/postfixer.d/virtual
TRANSPORT_MAP := $(POSTFIX_DIR)/postfixer.d/transport
VIRTUAL_ALIAS_MAP := $(VIRTUAL_DIR)/aliases

.PHONY: all maps aliases virtual transport reload check status help

all: maps reload

maps: aliases virtual transport

aliases: /etc/aliases.db $(VIRTUAL_ALIAS_MAP).db

/etc/aliases.db: /etc/aliases
	@echo "postalias $<"
	@postalias $<

$(VIRTUAL_ALIAS_MAP).db: $(VIRTUAL_ALIAS_MAP)
	@echo "postmap $<"
	@postmap $<

virtual: $(VIRTUAL_ALIAS_MAP).db
	@test -f $(VIRTUAL_DIR)/domains
	@test -f $(VIRTUAL_DIR)/aliases.regex

transport:
	@if [ -f $(TRANSPORT_MAP) ]; then postmap $(TRANSPORT_MAP); fi

reload: maps
	@postfix check
	@systemctl reload postfix.service

check:
	@postfix check
	@test -f $(VIRTUAL_DIR)/domains
	@test -f $(VIRTUAL_DIR)/aliases
	@test -f $(VIRTUAL_DIR)/aliases.regex
	@test -f $(VIRTUAL_ALIAS_MAP).db
	@if [ -f $(TRANSPORT_MAP) ]; then test -f $(TRANSPORT_MAP).db; fi
	@echo "Postfix maps and virtual lists are present."

status:
	@postfix status
	@postconf -h virtual_alias_domains virtual_alias_maps transport_maps

help:
	@printf '%s\n' \
		'make              - rebuild maps and reload Postfix' \
		'make maps         - rebuild hash maps only' \
		'make reload       - validate maps and reload Postfix' \
		'make check        - verify required files and databases' \
		'make status       - show Postfix status and active map settings'
