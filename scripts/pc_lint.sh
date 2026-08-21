#!/bin/bash
##################################################################################
## Lints staged files using:
## - yamllint for YAML
##################################################################################
set -eu

# Detect tool availability
has_yamllint=false


if yamllint --version &> /dev/null; then
  has_yamllint=true
else
  echo "WARN: Yamllint not available. Skipping YAML linting."
fi


# Run Yamllint
if [ has_yamllint ]; then
  yamllint $@ && echo "PASS: No linting errors." || {
    echo "FAIL: Linting errors."
    exit 1
  }
fi
