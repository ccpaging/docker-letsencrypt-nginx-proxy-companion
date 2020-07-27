#!/bin/bash

set -e

# Get acme.sh Let's Encrypt client source - master
mkdir /src
wget -O /src/master.zip https://github.com/acmesh-official/acme.sh/archive/master.zip
unzip /src/master.zip -d /src
cd /src/acme.sh-master
chmod +rx acme.sh

# Install acme.sh in /app
./acme.sh --install \
  --nocron \
  --noprofile \
  --log /dev/null \
  --auto-upgrade 0 \
  --home /app \
  --config-home /etc/acme.sh/default

# Make house cleaning
cd /
rm -rf /src
