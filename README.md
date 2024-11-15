# Cosmian Enclave Image Base

## Overview

Base image used for Python web application launched with [Cosmian Enclave](https://docs.cosmian.com/compute/cosmian_enclave/overview/).

The image is built and released with GitHub Actions as below:

```console
$ export BUILD_DATE="$(date "+%Y%m%d%H%M%S")"
$ docker build -t cenclave-base:$BUILD_DATE .
```

It is recommended to use images released on [pkgs/cenclave-base](https://github.com/Cosmian/cenclave-image-base/pkgs/container/cenclave-base) as base layer.

## Extend the image with your dependencies

As an example, `cenclave-base` can be extended with [Flask](https://flask.palletsprojects.com/en/stable/):

```
FROM ghcr.io/cosmian/cenclave-base:LAST_DATE_ON_GH_PACKAGES

RUN pip3 install "flask==3.1.0"
```

replace `LAST_DATE_ON_GH_PACKAGES` with the last one on [pkgs/cenclave-base](https://github.com/Cosmian/cenclave-image-base/pkgs/container/cenclave-base), then:

```console
$ docker build -t cenclave-flask:3.1.0
```

## Run with SGX

First compress your Python flask application:

```console
$ tree src/
src
└── app.py

0 directories, 2 files
$ cat src/app.py
from flask import Flask

app = Flask(__name__)

@app.route('/')
def hello():
    return "Hello World!"
$ tar -cvf /tmp/app.tar --directory=src app.py
```

then generate a signer RSA key for the enclave:

```console
$ openssl genrsa -3 -out enclave-key.pem 3072
```

and finally run the Docker container with:

- Enclave signer key mounted to `/root/.config/gramine/enclave-key.pem`
- Tar of the python application mounted anywhere (`/tmp/app.tar` can be used)
- `cenclave-run` binary as entrypoint
- Enclave size in `--size` (could be `2G`, `4G`, `8G`)
- Path of the tar file with the Python application in `--code`
- Module path of your web application in `--application` (usually `app:app`)
- Random UUID v4 in `--uuid`
- Expiration date of the certificate as unix epoch time in `--self-signed`

```console
$ docker run -p 8080:443 \
    --device /dev/sgx_enclave \
    --device /dev/sgx_provision \
    --device /dev/sgx/enclave \
    --device /dev/sgx/provision \
    -v /var/run/aesmd:/var/run/aesmd \
    -v "$(realpath enclave-key.pem)":/root/.config/gramine/enclave-key.pem \
    -v /tmp/app.tar:/tmp/app.tar \
    --entrypoint cenclave-run \
    cenclave-flask:3.1.0 --size 8G \
                    --code /tmp/app.tar \
                    --host localhost \
                    --application app:app \
                    --uuid 533a2b83-4bc5-4a9c-955e-208c530bfd15 \
                    --self-signed 1769155711
```

## Check your web application

```console
$ # get self-signed certificate with OpenSSL
$ openssl s_client -showcerts -connect localhost:8080 </dev/null 2>/dev/null | openssl x509 -outform PEM >/tmp/cert.pem
$ # force self-signed certificate as CA bundle
$ curl https://localhost:8080 --cacert /tmp/cert.pem
```

## Compute MRENCLAVE without SGX

The integrity of the application running in `cenclave-flask` is reflected in the `MRENCLAVE` value which is a SHA-256 hash digest of code, data, heap, stack, and other attributes of an enclave.

Use `--dry-run` parameter with the exact same other parameters as above to output `MRENCLAVE` value:

```console
$ docker run --rm \
    -v /tmp/app.tar:/tmp/app.tar \
    --entrypoint cenclave-run \
    cenclave-flask:3.1.0 --size 8G \
                    --code /tmp/app.tar \
                    --host localhost \
                    --application app:app \
                    --uuid 533a2b83-4bc5-4a9c-955e-208c530bfd15 \
                    --self-signed 1769155711 \
                    --dry-run
```

__Note__: `MRSIGNER` value should be ignored because it is randomly generated at each dry run.

## Testing Docker environment

If you want to test that your docker image contains all the dependencies needed, `cenclave-test` entrypoint wraps `flask run` command for you if you mount your code directory to `/app`:

```console
$ docker run --rm -ti \
    --entrypoint cenclave-test \
    --net host \
    -v src:/app \
    cenclave-flask:3.1.0 \
    --application app:app \
    --debug
$ # default host and port of flask developement server
$ curl http://127.0.0.1:5000
```

To use your `secrets.json`, just add `-v secrets.json:/root/.cache/cenclave/secrets.json` to mount the file.


## Determine the enclave memory size of your image

Some files contained in the image are mounted into the enclave: libs, etc. 
These files takes some memory spaces from the enclave size you have declared. The remaining space is the effective memory your app can use.

You can compute the effective memory by adding `--memory` in the previous commands:

```console
$ docker run --rm \
    -v /tmp/app.tar:/tmp/app.tar \
    --entrypoint cenclave-run \
    cenclave-flask:3.1.0 --size 8G \
                    --code /tmp/app.tar \
                    --host localhost \
                    --application app:app \
                    --uuid 533a2b83-4bc5-4a9c-955e-208c530bfd15 \
                    --self-signed 1769155711 \
                    --dry-run \
                    --memory
```
