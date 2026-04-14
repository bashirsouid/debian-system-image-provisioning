#!/bin/bash
set -e

mkdir -p third-party
cd third-party

echo "==> Checking AwesomeWM source..."
if [ -d "awesome/.git" ]; then
    echo "==> Updating existing AwesomeWM repository..."
    cd awesome
    git pull
else
    echo "==> Cloning AwesomeWM repository..."
    git clone --depth 1 https://github.com/awesomewm/awesome.git
fi

echo "==> Third-party dependencies are up to date."
