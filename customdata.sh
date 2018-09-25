#!/bin/bash

mkdir /tmp/testapp
cd /tmp/testapp
git clone https://github.com/kskvarci/kv-demo.git
cd kv-demo
apt install python-pip -y
pip install -r requirements.txt
