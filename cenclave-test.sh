#!/bin/bash

set -e

usage() {
    echo "cenclave-test usage: $0 --application <module:application> [--debug] "
    echo ""
    echo "Example: $0 --application app:app --debug"
    exit 1
}

set_default_variables() {
    APPLICATION=""
    APP_DIR="/app"
    DEBUG=""
}

parse_args() {
    echo "Reading args: $*"
    # Parse args
    while [[ $# -gt 0 ]]; do
        case $1 in
            --application)
            APPLICATION="$2"
            shift # past argument
            shift # past value
            ;;
            --debug)
            DEBUG="--debug"
            shift # past argument
            ;;
            -*)
            usage
            ;;
        esac
    done

    if [ -z "$APPLICATION" ]
    then
        echo "You must provide the path to the WSGI/ASGI application"
        exit 1
    fi
}

set_default_variables
parse_args "$@"

# Don't write .pyc files
export PYTHONDONTWRITEBYTECODE=1
# Other directory for __pycache__ folders
export PYTHONPYCACHEPREFIX=/tmp

export TMP_PATH=/tmp
export HOME=/root
export KEY_PATH=/key
export SECRETS_PATH=/root/.cache/cenclave/secrets.json
export SEALED_SECRETS_PATH="/root/.cache/cenclave/sealed_secrets.json"
export MODULE_PATH=/app

mkdir "$KEY_PATH"

# shellcheck source=/dev/null
. "$GRAMINE_VENV/bin/activate"

# Install dependencies
if [ -e "$APP_DIR/requirements.txt" ]; then
    echo "Installing deps..."
    pip install -r "$APP_DIR/requirements.txt"
fi

if [ -z "$DEBUG" ]; then
    PYTHONPATH="$(realpath $APP_DIR)" hypercorn --bind 0.0.0.0:5000 --worker-class uvloop --workers 1 "$APPLICATION"
else
    PYTHONPATH="$(realpath $APP_DIR)" hypercorn --bind 0.0.0.0:5000 --worker-class uvloop --workers 1 --log-level DEBUG "$APPLICATION"
fi
