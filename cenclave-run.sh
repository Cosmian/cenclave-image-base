#!/bin/bash

set -e

usage() {
    echo "cenclave-run usage: $0 --size <size> --san <domain_name> --application <module:application> --id <uuid> [--host <host>] [--port <port>] [--subject <subject>] [--expiration <expiration_timestamp>] [--timeout <seconds>] [--dry-run] [--memory] "
    echo ""
    echo "The code tar [mandatory] (app.tar) and the SSL certificate [optional] (fullchain.pem) should be placed in $PACKAGE_DIR"
    echo ""
    echo "Example: $0 --size 8G --expiration 1669155711 --san localhost --application app:app --id 533a2b83-4bc5-4a9c-955e-208c530bfd15"
    echo ""
    echo "Arguments:"
    echo -e "\t--debug      put the enclave in debug mode"
    echo -e "\t--dry-run    allow to compute MRENCLAVE value from a non-sgx machine"
    echo -e "\t--expiration the expiration date of the ratls. Mandatory if no certificate provided in $PACKAGE_DIR"
    echo -e "\t--force      regenerate and recompile files if they are already existed from another enclave"
    echo -e "\t--host       set the server host (default: $HOST)"
    echo -e "\t--memory     print the memory usage"
    echo -e "\t--port       set the server port (default: $PORT)"
    echo -e "\t--subject    set the ratls certificat subject as an RFC 4514 string (default: $SUBJECT)"
    echo -e "\t--timeout    stop the configuration server after this delay (in seconds)"

    exit 1
}

set_default_variables() {
    # Mandatory args (initialized empty)
    ENCLAVE_SIZE=""
    APPLICATION=""
    ID=""
    SUBJECT_ALTERNATIVE_NAME=""

    # Optional args
    EXPIRATION_DATE=""
    TIMEOUT=""
    DEBUG=0
    DRY_RUN=0
    MEMORY=0
    FORCE=0
    HOST="0.0.0.0"
    PORT="443"
    SUBJECT="CN=cosmian.io,O=Cosmian Tech,C=FR,L=Paris,ST=Ile-de-France"

    # Constant variables
    PACKAGE_DIR="/opt/input" # Location of the src package
    PACKAGE_CODE_TARBALL="$PACKAGE_DIR/app.tar"
    PACKAGE_CERT_PATH="$PACKAGE_DIR/fullchain.pem"

    # We will uncompress in the same directy than input
    # Because we don't want to take disk space on the space allocated to the user in the docker
    APP_DIR="/opt/input/app" 
    CERT_PATH="$APP_DIR/fullchain.pem"
    SGX_SIGNER_KEY="$HOME/.config/gramine/enclave-key.pem"
    CODE_DIR="code"
    HOME_DIR="home"
    KEY_DIR="key"
    MANIFEST_SGX="python.manifest.sgx"
}

parse_args() {
    echo "Reading args: $*"
    # Parse args
    while [[ $# -gt 0 ]]; do
        case $1 in
            --size)
            ENCLAVE_SIZE="$2"
            shift # past argument
            shift # past value
            ;;

            --expiration)
            EXPIRATION_DATE="$2"
            shift # past argument
            shift # past value
            ;;

            --host)
            HOST="$2"
            shift # past argument
            shift # past value
            ;;

            --port)
            PORT="$2"
            shift # past argument
            shift # past value
            ;;

            --application)
            APPLICATION="$2"
            shift # past argument
            shift # past value
            ;;

            --id)
            ID="$2"
            shift # past argument
            shift # past value
            ;;

            --subject)
            SUBJECT="$2"
            shift # past argument
            shift # past value
            ;;

            --san)
            SUBJECT_ALTERNATIVE_NAME="$2"
            shift # past argument
            shift # past value
            ;;

            --timeout)
            TIMEOUT="$2"
            shift # past argument
            shift # past value
            ;;

            --dry-run)
            DRY_RUN=1
            shift # past argument
            ;;

            --memory)
            MEMORY=1
            shift # past argument
            ;;

            --debug)
            DEBUG=1
            shift # past argument
            ;;

            --force)
            FORCE=1
            shift # past argument
            ;;

            -*)
            usage
            ;;
        esac
    done

    if [ -z "$ENCLAVE_SIZE" ] || [ -z "$SUBJECT_ALTERNATIVE_NAME" ] || [ -z "$APPLICATION" ] || [ -z "$ID" ]
    then
        usage
    fi

    if [ -z "$EXPIRATION_DATE" ] && ! [ -e "$PACKAGE_CERT_PATH" ]
    then
        echo "You have to use --expiration when the certificate is not providing in $PACKAGE_DIR"
        exit 1
    fi
}

set_default_variables
parse_args "$@"

# Don't write .pyc files
export PYTHONDONTWRITEBYTECODE=1
# Other directory for __pycache__ folders
export PYTHONPYCACHEPREFIX=/tmp

OWNER_GROUP=$(stat -c "%u:%g" "$PACKAGE_CODE_TARBALL")

# If the manifest exist, ignore all the installation and compilation steps
# Do it anyways if --force
if [ ! -f $MANIFEST_SGX ] || [ $FORCE -eq 1 ]; then
    echo "Untar the code..."
    mkdir -p "$APP_DIR"
    APP_DIR_OWNER_GROUP=$(stat -c "%u:%g" "$APP_DIR")

    tar xvf "$PACKAGE_CODE_TARBALL" -C "$APP_DIR" --no-same-owner

    if [ "$OWNER_GROUP" != "$APP_DIR_OWNER_GROUP" ]; then
        # We should put the same owner to the untar files to be able to 
        # remove them outside the docker when computing the MREnclave for instance
        chown -R "$OWNER_GROUP" "$APP_DIR"
    fi

    # Install dependencies
    # /!\ should not be used to verify MRENCLAVE on client side
    # even if you freeze all your dependencies in a requirements.txt file
    # there are side effects and hash digest of some files installed may differ
    if [ -e "$APP_DIR/requirements.txt" ]; then
        echo "Installing deps..."
        if [ -n "$GRAMINE_VENV" ]; then
            # shellcheck source=/dev/null
            . "$GRAMINE_VENV/bin/activate"
        fi
        pip install -r $APP_DIR/requirements.txt
        if [ -n "$GRAMINE_VENV" ]; then
            deactivate
        fi
    fi

    # Prepare the certificate if necessary
    if [ -f "$PACKAGE_CERT_PATH" ]; then
        cp "$PACKAGE_CERT_PATH" "$CERT_PATH"

        CERT_PATH_OWNER_GROUP=$(stat -c "%u:%g" "$CERT_PATH")
        if [ "$OWNER_GROUP" != "$CERT_PATH_OWNER_GROUP" ]; then
            chown -R "$OWNER_GROUP" "$CERT_PATH"
        fi

        SSL_APP_MODE="--certificate"
        SSL_APP_MODE_VALUE="$CERT_PATH"
    else
        SSL_APP_MODE="--ratls"
        SSL_APP_MODE_VALUE="$EXPIRATION_DATE"
    fi

    # Remove previous generated files if exists
    if [ $FORCE -eq 1 ]; then
        rm -rf $CODE_DIR $HOME_DIR $KEY_DIR
    fi

    TIMEOUT_MODE=""
    if [ -n "$TIMEOUT" ]; then
        TIMEOUT_MODE="--timeout"
    fi

    # Prepare gramine argv
    # /!\ no double quote around $SSL_APP_MODE_VALUE which might be empty
    # otherwise it will be serialized by gramine
    gramine-argv-serializer "/usr/bin/python3" "-S" "/usr/local/bin/cenclave-bootstrap" \
        "$SSL_APP_MODE" $SSL_APP_MODE_VALUE \
        "--host" "$HOST" \
        "--port" "$PORT" \
        "--app-dir" "$APP_DIR" \
        "--subject" "$SUBJECT" \
        "--san" "$SUBJECT_ALTERNATIVE_NAME" \
        "--id" "$ID" \
        $TIMEOUT_MODE $TIMEOUT \
        "$APPLICATION" > args

    echo "Generating the enclave..."

    if [ $DRY_RUN -eq 1 ]; then
        # Generate a dummy key if you just want to get MRENCLAVE
        gramine-sgx-gen-private-key
    fi

    VENV=""
    if [ -n "$GRAMINE_VENV" ]; then
        VENV="GRAMINE_VENV=$GRAMINE_VENV"
    fi

    # Build the gramine program
    make clean && make SGX=1 $VENV \
                    DEBUG="$DEBUG" \
                    ENCLAVE_SIZE="$ENCLAVE_SIZE" \
                    APP_DIR="$APP_DIR" \
                    SGX_SIGNER_KEY="$SGX_SIGNER_KEY" \
                    CODE_DIR="$CODE_DIR" \
                    HOME_DIR="$HOME_DIR" \
                    KEY_DIR="$KEY_DIR"
fi

if [ $MEMORY -eq 1 ]; then
    cenclave-memory python.manifest.sgx
fi

if [ $DRY_RUN -eq 0 ]; then
    if ! [ -e "/dev/sgx_enclave" ]; then
        echo "You are not running on an sgx machine"
        echo "If you want to compute the MR_ENCLAVE, re-run with --dry-run parameter"
        exit 1
    fi

    # Start the enclave
    gramine-sgx ./python
fi
