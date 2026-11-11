SHELL := /bin/bash
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

.DEFAULT_GOAL := help
.PHONY: help install up down stop start restart status logs test images save-images uninstall check

help:
	@printf '\n k3d on WSL - reusable local Kubernetes\n\n'
	@printf '  make install       Install pinned k3d + enable Docker (idempotent)\n'
	@printf '  make images        Pull all images the cluster needs (one-time / after version bump)\n'
	@printf '  make up            Create the cluster if missing, otherwise reuse/start it\n'
	@printf '  make status        Show nodes, pods, ingress and endpoints\n'
	@printf '  make test          Deploy a demo app and verify ingress, storage, registry\n'
	@printf '  make stop          Stop the cluster, keep all state\n'
	@printf '  make start         Start a stopped cluster\n'
	@printf '  make restart       Restart all cluster nodes\n'
	@printf '  make logs          Show k3s server logs (ARGS="agent -f" for others)\n'
	@printf '  make down          Delete the cluster, keep images and k3d\n'
	@printf '  make save-images   Export images to images/*.tar for offline reuse\n'
	@printf '  make uninstall     Delete cluster + k3d binary (ARGS="--purge" for everything)\n\n'
	@printf '  make check         Shell syntax check (and shellcheck if installed)\n\n'
	@printf '  make help          This help\n\n'

install:
	bash $(ROOT)/scripts/install.sh $(ARGS)

images:
	bash $(ROOT)/scripts/prepare-images.sh $(ARGS)

save-images:
	bash $(ROOT)/scripts/prepare-images.sh --save $(ARGS)

up:
	bash $(ROOT)/scripts/up.sh $(ARGS)

down:
	bash $(ROOT)/scripts/down.sh $(ARGS)

stop:
	bash $(ROOT)/scripts/stop.sh $(ARGS)

start:
	bash $(ROOT)/scripts/start.sh $(ARGS)

restart:
	bash $(ROOT)/scripts/restart.sh $(ARGS)

status:
	bash $(ROOT)/scripts/status.sh $(ARGS)

logs:
	bash $(ROOT)/scripts/logs.sh $(ARGS)

test:
	bash $(ROOT)/scripts/test.sh $(ARGS)

uninstall:
	bash $(ROOT)/scripts/uninstall.sh $(ARGS)

check:
	bash $(ROOT)/scripts/check.sh
